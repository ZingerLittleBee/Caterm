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

	/// Decision-driven sync state. See `SyncStateOutcome` for semantics.
	/// `suspendUntilFirstEdit` and `quarantined` look identical to a casual
	/// observer — both block observer-plane push — but they differ in how
	/// the next user edit is handled: suspendUntilFirstEdit unfreezes +
	/// pushes + persists token; quarantined does nothing (the next pull
	/// re-evaluates).
	public private(set) var syncState: SyncStateOutcome = .suspendUntilFirstEdit
	/// Transient write barrier covering Apple's `.initialSyncChange` grace
	/// window. Orthogonal to `syncState`: a user edit during grace defers
	/// to the post-grace classifier regardless of `syncState`.
	private var inInitialSyncGrace: Bool = false
	private var isSyncRunning: Bool = false

	// Test counters
	public private(set) var startSyncCallCount = 0
	public private(set) var observersRegisteredCount = 0

	// MARK: - Test hooks
	public var testInitialSyncTimeout: Duration = .seconds(3)
	public var testInitialSyncGrace: Duration = .milliseconds(500)
	public var testPushSuspended: Bool { syncState != .active || inInitialSyncGrace }
	public func testForceSyncState(_ s: SyncStateOutcome) { syncState = s }
	/// Back-compat shim: maps the legacy boolean to the two-valued slice of
	/// `SyncStateOutcome` it used to represent. New tests should call
	/// `testForceSyncState` directly so quarantine is reachable.
	public func testForcePushSuspended(_ v: Bool) {
		syncState = v ? .suspendUntilFirstEdit : .active
	}
	public func testPostExternalChange(reason: Int) {
		NotificationCenter.default.post(
			name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
			object: nil,
			userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: reason]
		)
	}
	private var bootDecisionTask: Task<Void, Never>?
	private var pullTask: Task<Void, Never>?

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
		syncState = .suspendUntilFirstEdit  // initial barrier; bootSequence overrides

		let task = Task { @MainActor [weak self] in
			await self?.runBootSequence()
			guard let self = self, !Task.isCancelled, self.isSyncRunning else { return }
			self.registerSyncObservers()
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
		// Set the grace barrier synchronously so callers observing
		// `testPushSuspended` immediately after `testPostExternalChange`
		// see the barrier active without having to yield first.
		if case .initialSyncChange = reason {
			inInitialSyncGrace = true
		}
		pullTask = Task { @MainActor [weak self] in
			await self?.dispatchPull(reason: reason)
		}
	}

	private func dispatchPull(reason: KVSChangeReason) async {
		switch reason {
		case .quotaViolationChange:
			NSLog("[SettingsSyncStore] quota violation; key present? \(kvs.data(forKey: Self.kvsKey) != nil)")
			return
		case .initialSyncChange:
			inInitialSyncGrace = true
			try? await Task.sleep(for: testInitialSyncGrace)
			guard !Task.isCancelled, isSyncRunning else {
				inInitialSyncGrace = false
				return
			}
			// Clear the grace flag BEFORE classifyAndApply so the decision's
			// finalSuspensionState is the sole source of truth for whether
			// subsequent user edits should take the unfreeze path.
			inInitialSyncGrace = false
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

		// During the initial-sync grace window, defer to the post-grace
		// classifier. Taking the unfreeze branch here would (a) skip schema /
		// account-switch checks against the freshly-arrived blob and (b)
		// risk persisting the current identity token before the classifier
		// has decided whether the local data belongs there.
		if inInitialSyncGrace { return }

		switch syncState {
		case .quarantined:
			// We deliberately did NOT apply cloud (schema-newer or unreadable).
			// Pushing local now would clobber the cloud blob we refused to
			// touch. Let the next pull re-evaluate; user's local edit is still
			// persisted to disk by SettingsStore — it just doesn't reach KVS.
			return

		case .suspendUntilFirstEdit:
			// CRITICAL ORDERING: unfreeze BEFORE the push for this same edit so
			// that quitting after one edit still leaves the cloud blob populated.
			syncState = .active
			pushLocalToKVS()
			// Persist the current token — user has accepted identity Y by
			// authoring data under it.
			if let token = currentTokenProvider() {
				tokenStore.persist(token)
			}

		case .active:
			pushLocalToKVS()
		}
	}

	public func stopSync() {
		guard isSyncRunning else { return }
		isSyncRunning = false
		// Cancel any in-flight boot or pull task. Without this, a sleeping
		// task wakes up after stopSync, calls applyDecision, persists a
		// token, transitions state, and (for boot) re-installs the very
		// observers we just removed.
		bootDecisionTask?.cancel()
		bootDecisionTask = nil
		pullTask?.cancel()
		pullTask = nil
		inInitialSyncGrace = false
		if let token = kvsExternalObserver {
			NotificationCenter.default.removeObserver(token)
			kvsExternalObserver = nil
		}
		if let token = settingsChangeObserver {
			NotificationCenter.default.removeObserver(token)
			settingsChangeObserver = nil
		}
		syncState = .suspendUntilFirstEdit
	}

	private func runBootSequence() async {
		// Trigger initial pull and wait briefly. We don't yet subscribe to
		// didChangeExternallyNotification — production wiring lands in Task 16.
		_ = kvs.synchronize()
		try? await Task.sleep(for: testInitialSyncTimeout)
		// stopSync may have run while we were sleeping. Bail out before we
		// touch state — applyDecision would otherwise persist a token and
		// transition syncState out from under stopSync.
		guard !Task.isCancelled, isSyncRunning else { return }

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

	private func decodeCloud() -> CloudReadResult {
		guard let data = kvs.data(forKey: Self.kvsKey) else { return .absent }
		do {
			return .decoded(try SettingsBlobCodec.decode(data))
		} catch {
			return .unreadable(error)
		}
	}

	private func applyDecision(
		_ decision: Decision,
		currentToken: (NSObject & NSCoding & NSCopying)?
	) async {
		var applyFailed = false
		switch decision.action {
		case .noOp:
			break
		case .pushLocal:
			pushLocalToKVS()
		case .applyCloud(let blob), .forceApply(let blob):
			do {
				try applyCloudToLocal(blob)
			} catch {
				NSLog("[SettingsSyncStore] applyCloudToLocal failed: \(error)")
				applyFailed = true
			}
		case .rejectMerge:
			break
		case .suspendUntilFirstEdit:
			break
		}

		if applyFailed {
			// Apply failed mid-decision. Roll back: do NOT persist the
			// identity token (next boot will re-classify and retry), and do
			// NOT transition out of the current suspension. The next pull
			// will reach this code path again with fresh state.
			return
		}

		if decision.acceptIdentity, let token = currentToken {
			tokenStore.persist(token)
		}
		syncState = decision.finalState
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

	private func applyCloudToLocal(_ blob: SyncableSettings) throws {
		let next = blob.toLocal(localMigrationsCompleted: store.settings.migrationsCompleted)
		try store.replaceFromSync(next)
	}

	private func knownMigrationsAtBoot() -> Set<String> {
		return [SettingsMigrationStep.token]
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
