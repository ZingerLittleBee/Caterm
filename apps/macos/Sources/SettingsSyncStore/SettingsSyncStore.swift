import Foundation
import SettingsStore

/// Minimal surface of CloudKit's iCloudAccountSession we depend on, so this
/// module doesn't link CloudKit directly — the concrete iCloudAccountSession
/// from CloudKitSyncClient implements this implicitly.
public protocol AccountSessionProviding: AnyObject {
	var isSignedIn: Bool { get }
	func refresh() async
}

public extension Notification.Name {
	static let catermICloudAccountChanged =
		Notification.Name("catermICloudAccountChanged")
}

@MainActor
public final class SettingsSyncStore {
	public static let kvsKey = "caterm.settings.v1"

	private let store: SettingsStore
	private let kvs: KVSProtocol
	private let accountSession: AccountSessionProviding
	private let tokenStore: IdentityTokenStore
	private let currentTokenProvider: () -> (NSObject & NSCoding & NSCopying)?

	// Lifecycle observer (app-lifetime)
	private var accountChangeObserver: NSObjectProtocol?

	// Sync observers (registered by startSync, removed by stopSync)
	private var kvsExternalObserver: NSObjectProtocol?
	private var settingsChangeObserver: NSObjectProtocol?

	public var pushSuspended: Bool = true   // initial barrier — cleared by startSync's decision pass
	private var isSyncRunning: Bool = false

	// Test counters
	public private(set) var startSyncCallCount = 0
	public private(set) var observersRegisteredCount = 0

	// MARK: - Test hooks
	public var testInitialSyncTimeout: Duration = .seconds(3)
	public var testInitialSyncGrace: Duration = .milliseconds(500)
	public var testPushSuspended: Bool { pushSuspended }
	public func testForcePushSuspended(_ v: Bool) { pushSuspended = v }
	public func testPostExternalChange(reason: Int) {
		NotificationCenter.default.post(
			name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
			object: nil,
			userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: reason]
		)
	}
	private var bootDecisionTask: Task<Void, Never>?

	public func testWaitForBootDecision() async {
		_ = await bootDecisionTask?.value
	}

	public init(
		store: SettingsStore,
		kvs: KVSProtocol,
		accountSession: AccountSessionProviding,
		tokenStore: IdentityTokenStore,
		currentTokenProvider: @escaping () -> (NSObject & NSCoding & NSCopying)?
	) {
		self.store = store
		self.kvs = kvs
		self.accountSession = accountSession
		self.tokenStore = tokenStore
		self.currentTokenProvider = currentTokenProvider
	}

	/// App-lifetime observer for sign-in transitions. Called once at app
	/// startup; the observer is NEVER removed for the life of the process.
	public func installLifecycleObservers() {
		guard accountChangeObserver == nil else { return }
		accountChangeObserver = NotificationCenter.default.addObserver(
			forName: .catermICloudAccountChanged, object: nil, queue: .main
		) { [weak self] _ in
			Task { @MainActor [weak self] in
				guard let self = self else { return }
				if self.accountSession.isSignedIn && !self.isSyncRunning {
					await self.startSync()
				} else if !self.accountSession.isSignedIn && self.isSyncRunning {
					self.stopSync()
				}
			}
		}
	}

	public func startSync() async {
		startSyncCallCount += 1
		if isSyncRunning { return }
		guard accountSession.isSignedIn else { return }
		isSyncRunning = true
		observersRegisteredCount += 1
		pushSuspended = true

		let task = Task { @MainActor [weak self] in
			await self?.runBootSequence()
			self?.registerSyncObservers()
		}
		bootDecisionTask = task
	}

	private func registerSyncObservers() {
		if settingsChangeObserver == nil {
			settingsChangeObserver = NotificationCenter.default.addObserver(
				forName: SettingsStore.changeNotification, object: store, queue: .main
			) { [weak self] note in
				Task { @MainActor [weak self] in
					self?.handleLocalSettingsChange(note: note)
				}
			}
		}
		if kvsExternalObserver == nil {
			kvsExternalObserver = NotificationCenter.default.addObserver(
				forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
				object: nil, queue: .main
			) { [weak self] note in
				MainActor.assumeIsolated {
					self?.handleKVSExternalChange(note: note)
				}
			}
		}
	}

	private func handleKVSExternalChange(note: Notification) {
		let raw = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
		let reason = KVSReasonClassifier.classify(raw)
		// For .initialSyncChange we set the barrier synchronously so callers
		// observing immediately after the post see pushSuspended == true.
		if case .initialSyncChange = reason {
			pushSuspended = true
		}
		Task { @MainActor [weak self] in
			await self?.dispatchPull(reason: reason)
		}
	}

	private func dispatchPull(reason: KVSChangeReason) async {
		switch reason {
		case .quotaViolationChange:
			NSLog("[SettingsSyncStore] quota violation; key present? \(kvs.data(forKey: Self.kvsKey) != nil)")
			return
		case .initialSyncChange:
			pushSuspended = true
			try? await Task.sleep(for: testInitialSyncGrace)
			await classifyAndApply()
		case .serverChange, .accountChange, .unknown:
			await classifyAndApply()
		}
	}

	private func classifyAndApply() async {
		let bootStartedAt = Date()
		let persisted = tokenStore.loadPersisted()
		let current = currentTokenProvider()
		let classification = TokenClassifier.classify(persisted: persisted, current: current)
		let cloud = decodeCloud()
		let decision: Decision
		switch classification {
		case .notSignedIn:
			stopSync(); return
		case .signedOut:
			stopSync(); return
		case .firstObservation, .identitySame:
			decision = BootstrapDecider.decide(
				local: store.settings, cloud: cloud,
				bootStartedAt: bootStartedAt,
				knownMigrations: knownMigrationsAtBoot()
			)
		case .identityChanged, .unknownPrevious:
			decision = AccountSwitchHandler.handle(local: store.settings, cloudY: cloud)
		}
		await applyDecision(decision, currentToken: current)
	}

	private func handleLocalSettingsChange(note: Notification) {
		let source = note.userInfo?[SettingsStore.sourceUserInfoKey] as? String ?? "local"
		if source == "sync" { return }
		if pushSuspended { return }
		pushLocalToKVS()
	}

	public func stopSync() {
		guard isSyncRunning else { return }
		isSyncRunning = false
		if let token = kvsExternalObserver {
			NotificationCenter.default.removeObserver(token)
			kvsExternalObserver = nil
		}
		if let token = settingsChangeObserver {
			NotificationCenter.default.removeObserver(token)
			settingsChangeObserver = nil
		}
		pushSuspended = true
	}

	private func runBootSequence() async {
		// Trigger initial pull and wait briefly. We don't yet subscribe to
		// didChangeExternallyNotification — production wiring lands in Task 16.
		_ = kvs.synchronize()
		try? await Task.sleep(for: testInitialSyncTimeout)

		let bootStartedAt = Date()
		let persisted = tokenStore.loadPersisted()
		let current = currentTokenProvider()
		let classification = TokenClassifier.classify(persisted: persisted, current: current)

		let cloud = decodeCloud()
		let decision: Decision
		switch classification {
		case .notSignedIn:
			stopSync()
			return
		case .firstObservation, .identitySame:
			decision = BootstrapDecider.decide(
				local: store.settings, cloud: cloud,
				bootStartedAt: bootStartedAt,
				knownMigrations: knownMigrationsAtBoot()
			)
		case .identityChanged, .unknownPrevious:
			decision = AccountSwitchHandler.handle(
				local: store.settings, cloudY: cloud
			)
		case .signedOut:
			stopSync()
			return
		}

		await applyDecision(decision, currentToken: current)
	}

	private func decodeCloud() -> SyncableSettings? {
		guard let data = kvs.data(forKey: Self.kvsKey) else { return nil }
		return try? SettingsBlobCodec.decode(data)
	}

	private func applyDecision(
		_ decision: Decision,
		currentToken: (NSObject & NSCoding & NSCopying)?
	) async {
		switch decision.action {
		case .noOp:
			break
		case .pushLocal:
			pushLocalToKVS()
		case .applyCloud(let blob), .forceApply(let blob):
			applyCloudToLocal(blob)
		case .rejectMerge:
			break
		case .suspendUntilFirstEdit:
			break
		}
		if decision.acceptIdentity, let token = currentToken {
			tokenStore.persist(token)
		}
		pushSuspended = decision.finalSuspensionState
	}

	private func pushLocalToKVS() {
		do {
			let blob = try SettingsBlobCodec.encode(store.settings)
			kvs.set(blob, forKey: Self.kvsKey)
			_ = kvs.synchronize()
		} catch {
			NSLog("[SettingsSyncStore] encode/push failed: \(error)")
		}
	}

	private func applyCloudToLocal(_ blob: SyncableSettings) {
		let next = blob.toLocal(localMigrationsCompleted: store.settings.migrationsCompleted)
		do {
			try store.replaceFromSync(next)
		} catch {
			NSLog("[SettingsSyncStore] replaceFromSync failed: \(error)")
		}
	}

	private func knownMigrationsAtBoot() -> Set<String> {
		return ["settings-gui-v1"]
	}
}

public enum TokenClassification: Equatable {
	case notSignedIn
	case firstObservation     // prev nil, curr non-nil — no prior identity to leak
	case identitySame         // prev and curr both non-nil and isEqual
	case identityChanged      // prev and curr both non-nil and NOT isEqual
	case signedOut            // prev non-nil, curr nil
	case unknownPrevious      // sentinel "<archive-failed>" — route conservatively
}

public enum TokenClassifier {
	public static func classify(
		persisted: PersistedTokenLoad,
		current: (NSObject & NSCoding & NSCopying)?
	) -> TokenClassification {
		if case .archiveFailed = persisted { return .unknownPrevious }
		switch (persisted, current) {
		case (.none, nil): return .notSignedIn
		case (.none, _?): return .firstObservation
		case (.token, nil): return .signedOut
		case (.token(let prev), let curr?):
			return prev.isEqual(curr) ? .identitySame : .identityChanged
		default: return .notSignedIn   // unreachable; .archiveFailed handled above
		}
	}
}
