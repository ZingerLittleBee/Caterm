import Combine
import Foundation
import SettingsStore
import SyncScheduler

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

public enum SettingsSyncExecutionResult: Equatable, Sendable {
	case signedOut
	case upToDate(Date)
	case failed(String)
}

package struct SettingsSyncConfiguration: Sendable {
	package static let live = SettingsSyncConfiguration(
		bootTimeout: .seconds(3),
		initialSyncGrace: .milliseconds(500)
	)

	package let bootTimeout: Duration
	package let initialSyncGrace: Duration

	package init(bootTimeout: Duration, initialSyncGrace: Duration) {
		self.bootTimeout = bootTimeout
		self.initialSyncGrace = initialSyncGrace
	}
}

@MainActor
public final class SettingsSyncStore {
	private struct PullRequest {
		let reason: KVSChangeReason
		let lifecycleGeneration: UInt64
	}

	public static let kvsKey = "caterm.settings.v1"

	private let store: SettingsStore
	private let kvs: KVSProtocol
	private let accountSession: AccountSessionProviding
	private let tokenStore: IdentityTokenStore
	private let currentTokenProvider: () -> (NSObject & NSCoding & NSCopying)?
	private let configuration: SettingsSyncConfiguration

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
	private var lifecycleGeneration: UInt64 = 0
	private var lastOperationFailureMessage: String?
	@Published public private(set) var lastExecutionResult: SettingsSyncExecutionResult = .signedOut

	public var executionResultPublisher: AnyPublisher<SettingsSyncExecutionResult, Never> {
		$lastExecutionResult.eraseToAnyPublisher()
	}

	package var isPushSuspended: Bool {
		syncState != .active || inInitialSyncGrace
	}

	private var bootDecisionTask: Task<Void, Never>?
	private lazy var pullScheduler = SyncScheduler<PullRequest>(
		strategy: .latest,
		operation: { [weak self] request in
			await self?.dispatchPull(request)
		}
	)

	private init(
		store: SettingsStore,
		kvs: KVSProtocol,
		accountSession: AccountSessionProviding,
		tokenStore: IdentityTokenStore,
		currentTokenProvider: @escaping () -> (NSObject & NSCoding & NSCopying)?,
		resolvedConfiguration: SettingsSyncConfiguration
	) {
		self.store = store
		self.kvs = kvs
		self.accountSession = accountSession
		self.tokenStore = tokenStore
		self.currentTokenProvider = currentTokenProvider
		self.configuration = resolvedConfiguration
	}

	public convenience init(
		store: SettingsStore,
		kvs: KVSProtocol,
		accountSession: AccountSessionProviding,
		tokenStore: IdentityTokenStore,
		currentTokenProvider: @escaping () -> (NSObject & NSCoding & NSCopying)?
	) {
		self.init(
			store: store,
			kvs: kvs,
			accountSession: accountSession,
			tokenStore: tokenStore,
			currentTokenProvider: currentTokenProvider,
			resolvedConfiguration: .live
		)
	}

	package convenience init(
		store: SettingsStore,
		kvs: KVSProtocol,
		accountSession: AccountSessionProviding,
		tokenStore: IdentityTokenStore,
		currentTokenProvider: @escaping () -> (NSObject & NSCoding & NSCopying)?,
		configuration: SettingsSyncConfiguration
	) {
		self.init(
			store: store,
			kvs: kvs,
			accountSession: accountSession,
			tokenStore: tokenStore,
			currentTokenProvider: currentTokenProvider,
			resolvedConfiguration: configuration
		)
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
		_ = await startSyncAndReport()
	}

	@discardableResult
	public func startSyncAndReport() async -> SettingsSyncExecutionResult {
		if isSyncRunning {
			_ = await bootDecisionTask?.value
			publishExecutionResult()
			return lastExecutionResult
		}
		guard accountSession.isSignedIn else {
			lastExecutionResult = .signedOut
			return .signedOut
		}
		lifecycleGeneration &+= 1
		let generation = lifecycleGeneration
		isSyncRunning = true
		syncState = .suspendUntilFirstEdit  // initial barrier; bootSequence overrides

		let task = Task { @MainActor [weak self] in
			await self?.runBootSequence(lifecycleGeneration: generation)
			guard let self,
			      !Task.isCancelled,
			      self.ownsLifecycle(generation) else { return }
			self.registerSyncObservers()
		}
		bootDecisionTask = task
		await task.value
		publishExecutionResult()
		return lastExecutionResult
	}

	/// Explicit foreground refresh used by native pull-to-refresh and Sync Now.
	/// Local settings remain available if KVS is offline; the next external
	/// change or lifecycle retry re-evaluates the same decision state machine.
	@discardableResult
	public func synchronizeNow() async -> SettingsSyncExecutionResult {
		guard accountSession.isSignedIn else {
			lastExecutionResult = .signedOut
			stopSync()
			return .signedOut
		}
		guard isSyncRunning else {
			return await startSyncAndReport()
		}
		lastOperationFailureMessage = nil
		guard kvs.synchronize() else {
			lastExecutionResult = .failed(
				"Shared settings could not be saved locally for iCloud sync."
			)
			return lastExecutionResult
		}
		classifyAndApply(lifecycleGeneration: lifecycleGeneration)
		return lastExecutionResult
	}

	private func executionResult() -> SettingsSyncExecutionResult {
		if let lastOperationFailureMessage {
			return .failed(lastOperationFailureMessage)
		}
		guard isSyncRunning else { return lastExecutionResult }
		guard accountSession.isSignedIn else { return .signedOut }
		guard syncState != .quarantined else {
			return .failed(
				"Shared settings in iCloud could not be read or applied safely."
			)
		}
		return .upToDate(Date())
	}

	private func publishExecutionResult() {
		lastExecutionResult = executionResult()
	}

	private func registerSyncObservers() {
		if settingsChangeObserver == nil {
			settingsChangeObserver = NotificationCenter.default.addObserver(
				forName: SettingsStore.changeNotification, object: store, queue: .main
			) { [weak self] note in
				MainActor.assumeIsolated {
					guard let self else { return }
					let generation = self.lifecycleGeneration
					Task { @MainActor [weak self] in
						self?.handleLocalSettingsChange(
							note: note,
							lifecycleGeneration: generation
						)
					}
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
		// Supersede any in-flight pull. Without this, two overlapping
		// .initialSyncChange notifications spawn two grace tasks; the older
		// task wakes first and clears `inInitialSyncGrace` while the newer
		// task's grace window is still open — re-opening the C1 leak (a user
		// edit in that gap takes the unfreeze branch and pushes pre-grace
		// local state).
		// Update the grace barrier synchronously based on the *new* reason so
		// callers observing `isPushSuspended` immediately after a post see
		// the correct state without yielding. Setting / clearing here also
		// means the cancellation guard inside dispatchPull never has to touch
		// the flag (so a cancelled grace task can't clobber a newer one).
		switch reason {
		case .initialSyncChange:
			inInitialSyncGrace = true
		case .serverChange, .accountChange, .quotaViolationChange, .unknown:
			// A non-grace pull supersedes any prior grace. Leaving the flag
			// set would freeze user-edit pushes until the (now cancelled)
			// older grace task naturally completed.
			inInitialSyncGrace = false
		}
		_ = pullScheduler.submit(PullRequest(
			reason: reason,
			lifecycleGeneration: lifecycleGeneration
		))
	}

	private func dispatchPull(_ request: PullRequest) async {
		guard !Task.isCancelled,
		      ownsLifecycle(request.lifecycleGeneration) else { return }
		switch request.reason {
		case .quotaViolationChange:
			NSLog("[SettingsSyncStore] quota violation; key present? \(kvs.data(forKey: Self.kvsKey) != nil)")
			lastExecutionResult = .failed("iCloud shared settings exceeded the available quota.")
			return
		case .initialSyncChange:
			// `inInitialSyncGrace` was already set synchronously by
			// handleKVSExternalChange so observers see the barrier without
			// having to yield. Don't touch it here on the cancellation path —
			// supersede semantics in handleKVSExternalChange own the flag.
			try? await Task.sleep(for: configuration.initialSyncGrace)
			guard !Task.isCancelled,
			      ownsLifecycle(request.lifecycleGeneration) else { return }
			// Clear the grace flag BEFORE classifyAndApply so the decision's
			// finalState is the sole source of truth for whether subsequent
			// user edits should take the unfreeze path.
			inInitialSyncGrace = false
			classifyAndApply(lifecycleGeneration: request.lifecycleGeneration)
		case .serverChange, .accountChange, .unknown:
			guard !Task.isCancelled,
			      ownsLifecycle(request.lifecycleGeneration) else { return }
			classifyAndApply(lifecycleGeneration: request.lifecycleGeneration)
		}
	}

	private func classifyAndApply(lifecycleGeneration generation: UInt64) {
		guard ownsLifecycle(generation) else { return }
		lastOperationFailureMessage = nil
		let bootStartedAt = Date()
		let persisted = tokenStore.loadPersisted()
		let current = currentTokenProvider()
		let classification = TokenClassifier.classify(persisted: persisted, current: current)
		let cloud = decodeCloud()
		let decision: Decision
		switch classification {
		case .notSignedIn:
			lastExecutionResult = .signedOut
			stopSync(); return
		case .signedOut:
			lastExecutionResult = .signedOut
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
		applyDecision(
			decision,
			currentToken: current,
			lifecycleGeneration: generation
		)
		publishExecutionResult()
	}

	private func handleLocalSettingsChange(
		note: Notification,
		lifecycleGeneration generation: UInt64
	) {
		guard ownsLifecycle(generation) else { return }
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
			lastOperationFailureMessage = nil
			pushLocalToKVS()
			// Persist the current token — user has accepted identity Y by
			// authoring data under it.
			if case .upToDate = lastExecutionResult,
				let token = currentTokenProvider() {
				tokenStore.persist(token)
			}

		case .active:
			lastOperationFailureMessage = nil
			pushLocalToKVS()
		}
	}

	public func stopSync() {
		guard isSyncRunning else { return }
		lifecycleGeneration &+= 1
		isSyncRunning = false
		// Cancel any in-flight boot or pull task. Without this, a sleeping
		// task wakes up after stopSync, calls applyDecision, persists a
		// token, transitions state, and (for boot) re-installs the very
		// observers we just removed.
		bootDecisionTask?.cancel()
		bootDecisionTask = nil
		pullScheduler.cancel()
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

	private func runBootSequence(lifecycleGeneration generation: UInt64) async {
		// Trigger initial pull and wait briefly. We don't yet subscribe to
		// didChangeExternallyNotification — production wiring lands in Task 16.
		lastOperationFailureMessage = nil
		guard kvs.synchronize() else {
			lastExecutionResult = .failed(
				"Shared settings could not be saved locally for iCloud sync."
			)
			stopSync()
			return
		}
		try? await Task.sleep(for: configuration.bootTimeout)
		// stopSync may have run while we were sleeping. Bail out before we
		// touch state — applyDecision would otherwise persist a token and
		// transition syncState out from under stopSync.
		guard !Task.isCancelled, ownsLifecycle(generation) else { return }

		let bootStartedAt = Date()
		let persisted = tokenStore.loadPersisted()
		let current = currentTokenProvider()
		let classification = TokenClassifier.classify(persisted: persisted, current: current)

		let cloud = decodeCloud()
		let decision: Decision
		switch classification {
		case .notSignedIn:
			lastExecutionResult = .signedOut
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
			lastExecutionResult = .signedOut
			stopSync()
			return
		}

		applyDecision(
			decision,
			currentToken: current,
			lifecycleGeneration: generation
		)
		publishExecutionResult()
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
		currentToken: (NSObject & NSCoding & NSCopying)?,
		lifecycleGeneration generation: UInt64
	) {
		guard ownsLifecycle(generation) else { return }
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
			// Apply failed mid-decision. Roll back:
			// - Do NOT persist the identity token (a successor boot will
			//   re-classify and retry).
			// - Move to .quarantined so the observer-plane push is inhibited
			//   regardless of the prior state. This matters most when the
			//   prior state was .active: returning early without changing
			//   syncState would leave the next user edit free to push stale
			//   local state over the cloud blob we just failed to apply.
			//   The next pull re-evaluates and can clear quarantine.
			syncState = .quarantined
			lastOperationFailureMessage =
				"Shared settings from iCloud could not be applied safely."
			return
		}

		guard ownsLifecycle(generation) else { return }
		if decision.acceptIdentity, let token = currentToken {
			tokenStore.persist(token)
		}
		syncState = decision.finalState
	}

	private func ownsLifecycle(_ generation: UInt64) -> Bool {
		isSyncRunning && lifecycleGeneration == generation
	}

	private func pushLocalToKVS() {
		do {
			let blob = try SettingsBlobCodec.encode(store.settings)
			kvs.set(blob, forKey: Self.kvsKey)
			guard kvs.synchronize() else {
				lastOperationFailureMessage =
					"Shared settings could not be saved locally for iCloud sync."
				lastExecutionResult = .failed(lastOperationFailureMessage ?? "iCloud sync failed.")
				return
			}
			lastExecutionResult = .upToDate(Date())
		} catch {
			NSLog("[SettingsSyncStore] encode/push failed: \(error)")
			lastOperationFailureMessage = error.localizedDescription
			lastExecutionResult = .failed(error.localizedDescription)
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
