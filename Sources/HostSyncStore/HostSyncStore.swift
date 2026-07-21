import AppKit
import Combine
import CredentialSync
import CredentialSyncStore
import CredentialSyncTypes
import Foundation
import ServerSyncClient
import SSHCommandBuilder
import SessionStore
import SyncScheduler
import UserNotifications

public enum SyncErrorKind: Equatable, Sendable {
    case auth
    case other
}

public enum SyncFailureState: Equatable, Sendable {
    case normal
    case failing(reason: SyncErrorKind, since: Date)
}

public protocol NotificationDelivering: Sendable {
    func add(_ request: UNNotificationRequest) async throws
}

public struct LiveNotificationCenter: NotificationDelivering {
    public init() {}

    public func add(_ request: UNNotificationRequest) async throws {
        // UNUserNotificationCenter.current() raises an uncatchable Obj-C
        // NSException when the process has no bundle identity (dev-mode
        // bare-binary launches via `make run`). Skip cleanly there.
        guard Bundle.main.bundleIdentifier != nil else { return }
        try await UNUserNotificationCenter.current().add(request)
    }
}

/// Derives user-visible sync failure state from timestamps.
///
/// The threshold is based on `now - lastSyncedAt`; returned `.failing(... since:)`
/// uses `lastSyncAttemptedAt`. Store-level `failingSince` is handled separately.
///
/// Never-synced-with-error case: when `lastSyncedAt == nil` but a sync was
/// attempted and produced a known error kind, we surface `.failing` using
/// `lastSyncAttemptedAt` as `since`. Without this, a freshly-signed-in user
/// hitting an auth/network error on their first sync would render as
/// "Never synced" (healthy bucket) and silently miss the recovery affordance.
/// The threshold doesn't apply here — there's no successful baseline to
/// debounce against, and `lastSyncErrorKind` is only set after at least one
/// classified failure, so a stray nil-error transient can't flip us.
public func syncFailureState(
    now: Date,
    lastSyncedAt: Date?,
    lastSyncAttemptedAt: Date?,
    lastSyncErrorKind: SyncErrorKind?,
    periodicSyncEnabled: Bool,
    failingThreshold: TimeInterval
) -> SyncFailureState {
    guard periodicSyncEnabled else { return .normal }
    guard let attempted = lastSyncAttemptedAt else { return .normal }
    guard let succeeded = lastSyncedAt else {
        if let kind = lastSyncErrorKind {
            return .failing(reason: kind, since: attempted)
        }
        return .normal
    }
    guard attempted > succeeded else { return .normal }
    guard now.timeIntervalSince(succeeded) > failingThreshold else { return .normal }
    let reason = lastSyncErrorKind ?? .other
    return .failing(reason: reason, since: attempted)
}

public enum SyncMode: Sendable, Equatable {
    case auto
    case forceFull
    case incremental
}

/// Coordinates sync passes: fetch remote → reconcile → apply ops.
///
/// **Lifecycle:** must be held as `@StateObject` (or otherwise long-lived) by
/// the app. Reverting to a computed/short-lived instance silently breaks every
/// debounce, cancellation, and dedup guarantee in this design.
///
/// **Thread model:** `@MainActor` throughout. All scheduler /
/// `manualInProgress` / `pendingAutoAfterManual` / `currentManualTask`
/// reads-and-writes happen on the main actor; chain awaits release the actor
/// during the actual network/local work but reacquire it before observing or
/// writing any of the bookkeeping state.
@MainActor
public final class HostSyncStore: ObservableObject {
    private static let lastSyncedAtKey = "catermLastSyncedAt"
    private static let lastSyncAttemptedAtKey = "catermLastSyncAttemptedAt"
    // lastSyncErrorKind and failingSince are NOT persisted; cold start falls back
    // to .other when failure can be derived from timestamps.

    private let client: any IncrementalHostSyncClient
    private let sessionStore: SessionStore
    private let authSession: AuthSessionProtocol
    private let preferences: SyncPreferences
    private let credentialEngine: HostCredentialSyncEngine
    private let userDefaults: UserDefaults

    #if DEBUG
    /// Test-only seam: mirrors the ops applied during the most recent
    /// `performSync()` cycle. Reset at the start of the op-loop and
    /// appended to as each op is dispatched.
    internal private(set) var lastAppliedOpsForTesting: [SyncOperation] = []
    internal var decryptAndApplyInvocations: [
        (localHostId: UUID, revision: Int64)
    ] {
        credentialEngine.decryptAndApplyInvocations
    }
    #endif
    /// The view layer reads the same threshold used by failure detection.
    public let periodicInterval: TimeInterval
    private var cancellables: Set<AnyCancellable> = []
    private var periodicTimerCancellable: AnyCancellable?
    private var manualInProgress: Bool = false
    /// Edge tracker: was the previous sync cycle in the failing state?
    /// Transient (not persisted, not @Published). Cold-start re-evaluates
    /// via isCurrentlyFailing() and lets the next cycle trigger the edge
    /// naturally. Spec §2.2.3.
    private var wasFailing: Bool = false
    private var failureStateResetToken: Int = 0

    private let notificationCenter: NotificationDelivering
    private var pendingAutoAfterManual: Bool = false
    private var currentManualTask: Task<Void, Error>?
    private var manualTaskBeingSuspended: Task<Void, Error>?
    private var accountTransitionInProgress = false
    private lazy var scheduler = SyncScheduler<SyncMode>(
        strategy: .latest,
        onRunningStateChange: { [weak self] isRunning in
            self?.isSyncing = isRunning
        },
        operation: { [weak self] mode in
            guard let self else { return }
            try await self.performSync(mode: mode)
        }
    )

    /// "Last fully-applied sync." Set after performSync() completes the op
    /// loop without throwing. NOT updated when fetch fails or any
    /// apply(op) throws — see spec §4.2.
    @Published public private(set) var lastSyncedAt: Date?
    @Published public private(set) var lastSyncAttemptedAt: Date?
    @Published public private(set) var lastSyncErrorKind: SyncErrorKind?
    @Published public private(set) var failingSince: Date?
    @Published public private(set) var isSyncing: Bool = false

    /// Computed proxy so SwiftUI views can read sign-in state without holding
    /// the AuthSessionProtocol conformer directly (the conformer is not
    /// ObservableObject).
    /// Re-render relies on the app's coordinated sign-in / sign-out flows
    /// touching at least one @Published property on this store
    /// (sign-in → syncIfSignedIn → startSync flips isSyncing; auth-failure
    /// 401 → classifySyncError flips lastSyncErrorKind; recovery →
    /// clearAuthError flips failingSince/lastSyncErrorKind/lastSyncAttemptedAt).
    /// A caller that mutates `authSession.isSignedIn` without one of these
    /// store-side updates will leave this proxy stale until the next sync
    /// (spec Decision #23).
    public var isSignedIn: Bool { authSession.isSignedIn }

    public init(client: any IncrementalHostSyncClient,
                sessionStore: SessionStore,
                authSession: AuthSessionProtocol,
                preferences: SyncPreferences,
                credentialSync: CredentialSyncPreferencesStore,
                masterKeyStore: KeychainSyncMasterKeyStore = KeychainSyncMasterKeyStore(),
                debounceInterval: TimeInterval = 2.0,
                periodicInterval: TimeInterval = 60 * 60,
                userDefaults: UserDefaults = .standard,
                notificationCenter: NotificationDelivering = LiveNotificationCenter()) {
        self.client = client
        self.sessionStore = sessionStore
        self.authSession = authSession
        self.preferences = preferences
        self.credentialEngine = HostCredentialSyncEngine(
            client: client,
            sessionStore: sessionStore,
            preferences: credentialSync,
            masterKeyStore: masterKeyStore
        )
        self.periodicInterval = periodicInterval
        self.userDefaults = userDefaults

        // Hydrate from persistence.
        self.lastSyncedAt = userDefaults.object(forKey: Self.lastSyncedAtKey) as? Date
        self.lastSyncAttemptedAt = userDefaults.object(forKey: Self.lastSyncAttemptedAtKey) as? Date
        self.notificationCenter = notificationCenter

        sessionStore.mutationsForSync
            .debounce(for: .seconds(debounceInterval),
                      scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.scheduleAutoSync() }
            .store(in: &cancellables)

        // Spec §3.2: track preferences.periodicSyncEnabled — start/stop
        // the periodic timer. @Published .sink fires synchronously with
        // the current value, so on init this invokes
        // handlePeriodicEnabled(true) and starts the timer when the
        // default is true.
        preferences.$periodicSyncEnabled
            .sink { [weak self] enabled in self?.handlePeriodicEnabled(enabled) }
            .store(in: &cancellables)

        // Spec §3.2: listen for system wake (laptop opened from sleep).
        // NSWorkspace notifications post to NSWorkspace.shared.notificationCenter,
        // NOT NotificationCenter.default — using the wrong center silently
        // misses every wake event.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.handleSystemWake() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .catermCloudKitHostChanged)
            .sink { [weak self] _ in self?.scheduleAutoSync(mode: .auto) }
            .store(in: &cancellables)

        // Plan C / Task 15 — low-latency push path. SessionStore posts this
        // notification immediately after `setHostCredentialMaterial(...)`
        // persists hosts.json with `credentialMaterialDirty=true`. Schedule a
        // sync cycle so the dirty-scan can queue `.updateRemoteCredentials`
        // and the executor pushes the new ciphertext without waiting for the
        // periodic timer or another mutation event.
        NotificationCenter.default
            .publisher(for: .catermHostCredentialMaterialChanged)
            .sink { [weak self] note in
                guard let self else { return }
                let changedHostId = note.userInfo?[
                    CatermHostCredentialMaterialChangedKeys.hostId
                ] as? UUID
                if let changedHostId,
                   !self.credentialEngine.handleLocalCredentialChange(
                       hostId: changedHostId
                   ) {
                    return
                }
                self.scheduleAutoSync(mode: .auto)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public entry points

    /// Manual entry point ("Sync Now" button — and any future caller).
    /// Concurrent callers share the in-flight task's outcome instead of
    /// starting a second pass, so the public API is safe to call without
    /// external `disabled(isSyncing)`-style guards.
    public func sync() async throws {
        guard !accountTransitionInProgress else { throw CancellationError() }
        if let existing = currentManualTask {
            try await existing.value
            return
        }
        let task = Task<Void, Error> { [self] in
            try Task.checkCancellation()
            guard !accountTransitionInProgress else { throw CancellationError() }
            manualInProgress = true
            defer {
                manualInProgress = false
                currentManualTask = nil
                if pendingAutoAfterManual {
                    pendingAutoAfterManual = false
                    scheduleAutoSync()
                }
            }
            try Task.checkCancellation()
            guard !accountTransitionInProgress else { throw CancellationError() }
            try await startSync().value
        }
        currentManualTask = task
        try await task.value
    }

    /// Startup entry point. No-op when signed out; otherwise schedule a sync.
    /// Synchronous (non-async) — the `.task` modifier wraps it; the actual
    /// sync work runs as an unstructured Task owned by HostSyncStore.
    public func syncIfSignedIn() {
        guard !accountTransitionInProgress else { return }
        guard authSession.isSignedIn else { return }
        scheduleAutoSync()
    }

    /// Close the host-sync lane synchronously so a coordinator can gate every
    /// account-scoped store before awaiting any individual drain.
    public func beginAccountChangeSuspension() {
        guard !accountTransitionInProgress else { return }
        accountTransitionInProgress = true
        pendingAutoAfterManual = false
        manualTaskBeingSuspended = currentManualTask
        manualTaskBeingSuspended?.cancel()
        scheduler.cancel()
    }

    /// Drain work after `beginAccountChangeSuspension()` has closed the lane.
    public func drainForAccountChange() async {
        guard accountTransitionInProgress else { return }
        await scheduler.cancelAndDrain()
        _ = await manualTaskBeingSuspended?.result
        manualTaskBeingSuspended = nil
        currentManualTask = nil
        pendingAutoAfterManual = false
    }

    /// Convenience entry point for callers that only coordinate this store.
    public func suspendForAccountChange() async {
        beginAccountChangeSuspension()
        await drainForAccountChange()
    }

    public func resumeAfterAccountChange() {
        guard accountTransitionInProgress else { return }
        accountTransitionInProgress = false
        manualTaskBeingSuspended = nil
        syncIfSignedIn()
    }

    public func clearAuthError() {
        guard lastSyncErrorKind == .auth else { return }
        failureStateResetToken += 1
        lastSyncErrorKind = nil
        wasFailing = false
        failingSince = nil
        lastSyncAttemptedAt = nil
        userDefaults.removeObject(forKey: Self.lastSyncAttemptedAtKey)
    }

    // MARK: - Internal serialization

    /// Schedule an auto sync. Skipped (and deferred) while a manual sync
    /// is in progress — the deferred fire is replayed in manual's `defer`
    /// (see `sync()`).
    ///
    /// Auth gate (spec §3.2): all auto-paths (periodic, wake,
    /// mutation-debounce) inherit this gate. Signed-out users do not
    /// generate background server traffic. Manual `sync()` is intentionally
    /// exempt — its 401 surfacing is the recovery path for "session
    /// expired (cookie still present)" — see spec §4.4.1.
    private func scheduleAutoSync(mode: SyncMode = .auto) {
        guard !accountTransitionInProgress else { return }
        guard authSession.isSignedIn else { return }
        guard !manualInProgress else {
            pendingAutoAfterManual = true
            return
        }
        _ = startSync(mode: mode)
    }

    /// Start (or stop) the periodic timer based on the user's
    /// toggle setting. Idempotent — cancels and recreates the
    /// subscription each call, so re-arming on wake (§3.2 handleSystemWake)
    /// is safe.
    private func handlePeriodicEnabled(_ enabled: Bool) {
        periodicTimerCancellable?.cancel()
        periodicTimerCancellable = nil
        guard enabled else {
            failureStateResetToken += 1
            wasFailing = false
            failingSince = nil
            lastSyncErrorKind = nil
            lastSyncAttemptedAt = nil
            userDefaults.removeObject(forKey: Self.lastSyncAttemptedAtKey)
            return
        }
        periodicTimerCancellable = Timer.publish(every: periodicInterval,
                                                  on: .main,
                                                  in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.scheduleAutoSync(mode: .forceFull) }
    }

    /// Handle wake from sleep. Toggle-gated (spec §4.4) so a metered-
    /// connection user who turned off Background sync does not get a
    /// spontaneous network call when opening the lid.
    ///
    /// Re-arms the periodic timer so the next fire is `wake + interval`
    /// rather than the leftover schedule from before sleep. Sleep
    /// notification is deliberately ignored — Timer.publish naturally
    /// pauses across sleep (the runloop is suspended), and any spurious
    /// post-wake double-fire is absorbed by the chained cancel-and-drain.
    private func handleSystemWake() {
        guard preferences.periodicSyncEnabled else { return }
        scheduleAutoSync()
        handlePeriodicEnabled(true)
    }

    /// Submit to the shared latest-wins scheduler. Replacement cancels and
    /// drains the previous pass before starting, preserving mutual exclusion.
    @discardableResult
    private func startSync(mode: SyncMode = .auto) -> Task<Void, Error> {
        scheduler.submit(mode)
    }

    // MARK: - Sync work

    private func performSync(mode requestedMode: SyncMode = .auto) async throws {
        let failureStateToken = failureStateResetToken
        let attempted = Date()
        lastSyncAttemptedAt = attempted
        userDefaults.set(attempted, forKey: Self.lastSyncAttemptedAtKey)

        do {
            let credentialCycle = try await credentialEngine.beginCycle()
            guard case let .hostSync(requiresFullSnapshot) = credentialCycle else {
                // Destructive credential deletion is a side pipeline and must
                // not advance the user-visible host freshness timestamp.
                return
            }

            let effectiveMode: HostSyncMode
            switch requestedMode {
            case .auto:
                if requiresFullSnapshot {
                    effectiveMode = .forceFull
                } else {
                    effectiveMode = await client.preferredHostSyncMode()
                }
            case .forceFull:   effectiveMode = .forceFull
            case .incremental: effectiveMode = .incremental
            }

            var batch = try await fetch(effectiveMode)
            if batch.tokenExpired {
                // Single retry as forceFull. Token clearing already happened
                // inside the client.
                batch = try await fetch(.forceFull)
            }
            try Task.checkCancellation()

            let ops: [SyncOperation]
            switch batch.mode {
            case .forceFull:
                ops = HostSyncReconciler.reconcileFullSnapshot(
                    local: sessionStore.hosts, remote: batch.changedHosts
                )
            case .incremental:
                ops = HostSyncReconciler.reconcileDelta(
                    local: sessionStore.hosts,
                    changedHosts: batch.changedHosts,
                    deletedHostIDs: batch.deletedHostIDs
                )
            }
            let credentialOps = credentialEngine.credentialHostIDs().map {
                SyncOperation.updateRemoteCredentials(localHostId: $0)
            }
            let allOps = ops + credentialOps

            #if DEBUG
            lastAppliedOpsForTesting.removeAll(keepingCapacity: true)
            #endif
            for op in allOps {
                try Task.checkCancellation()
                #if DEBUG
                lastAppliedOpsForTesting.append(op)
                #endif
                try await apply(op, credentialBlobs: batch.credentialBlobsByServerId)
            }

            if let checkpoint = batch.checkpoint {
                try await client.commitHostCheckpoint(checkpoint)
                credentialEngine.didCommitCheckpoint()
            }

            // Spec §4.2: only update after the op loop completes without
            // throwing. Partial-apply failures must NOT advance freshness.
            let now = Date()
            lastSyncedAt = now
            userDefaults.set(now, forKey: Self.lastSyncedAtKey)
            lastSyncErrorKind = nil
            wasFailing = false
            failingSince = nil
        } catch {
            if isCancellation(error) { throw CancellationError() }
            if failureStateToken != failureStateResetToken { throw error }
            lastSyncErrorKind = classifySyncError(error)
            let nowFailing = isCurrentlyFailing()
            if !wasFailing && nowFailing {
                failingSince = lastSyncAttemptedAt
                if !manualInProgress && authSession.isSignedIn && preferences.notifyOnFailureEnabled {
                    await fireFailureNotification()
                }
            }
            if failureStateToken != failureStateResetToken { throw error }
            wasFailing = nowFailing
            throw error
        }
    }

    private func fetch(_ mode: HostSyncMode) async throws -> HostChangeBatch {
        switch mode {
        case .incremental: return try await client.fetchHostChanges()
        case .forceFull:   return try await client.fetchHostSnapshotAndCheckpoint()
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return Task.isCancelled
    }

    private func classifySyncError(_ error: Error) -> SyncErrorKind {
        if let serverError = error as? ServerSyncError, isAuthShape(serverError) {
            return .auth
        }
        return .other
    }

    private func isCurrentlyFailing() -> Bool {
        let state = syncFailureState(
            now: Date(),
            lastSyncedAt: lastSyncedAt,
            lastSyncAttemptedAt: lastSyncAttemptedAt,
            lastSyncErrorKind: lastSyncErrorKind,
            periodicSyncEnabled: preferences.periodicSyncEnabled,
            failingThreshold: periodicInterval
        )
        guard case .failing = state else { return false }
        return true
    }

    private func fireFailureNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Caterm sync is failing"
        content.body = "Click Sync Now in Sync Settings, or check your connection."
        let request = UNNotificationRequest(
            identifier: "caterm.sync.failing.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await notificationCenter.add(request)
    }

    private func apply(_ op: SyncOperation,
                       credentialBlobs: [String: CredentialBlob] = [:]) async throws {
        // ★ Critical invariant: do NOT insert Task.checkCancellation()
        // between client.createHost(...) and sessionStore.setServerId(...)
        // — see spec §4.2.1.
        switch op {
        case let .createRemote(localHostId):
            guard let host = sessionStore.hosts.first(where: { $0.id == localHostId }) else { return }
            let input = RemoteHostCreateInput(
                name: host.name, hostname: host.hostname,
                port: host.port, username: host.username,
                jumpHostServerId: host.jumpHostServerId,
                forwards: host.forwards,
                icon: host.icon,
                organization: host.organization,
                metadataUpdatedAt: host.updatedAt
            )
            let out = try await client.createHost(input)
            try sessionStore.setServerId(out.id, for: localHostId)

        case let .createLocal(remote):
            try sessionStore.addRemoteHost(remote)
            // If the snapshot carried a credential blob for this remote, run
            // it through the credential engine after creating the local host.
            // `addRemoteHost` allocates a fresh local UUID; look it up by
            // serverId rather than mutating addRemoteHost's signature.
            if let blob = credentialBlobs[remote.id],
               let local = sessionStore.hosts.last(where: { $0.serverId == remote.id }) {
                try await credentialEngine.applyRemoteBlob(
                    localHostId: local.id, remote: remote, blob: blob
                )
            }

        case let .updateRemote(localHostId, serverId):
            guard let host = sessionStore.hosts.first(where: { $0.id == localHostId }) else { return }
            let input = RemoteHostUpdateInput(
                id: serverId, name: host.name, hostname: host.hostname,
                port: host.port, username: host.username,
                jumpHostServerId: host.jumpHostServerId,
                forwards: host.forwards,
                icon: host.icon,
                organization: host.organization,
                metadataUpdatedAt: host.updatedAt
            )
            try await client.updateHost(input)

        case let .updateLocal(localHostId, remote):
            try sessionStore.applyRemoteMetadata(localHostId: localHostId, remote: remote)
            if let blob = credentialBlobs[remote.id] {
                try await credentialEngine.applyRemoteBlob(
                    localHostId: localHostId, remote: remote, blob: blob
                )
            }

        case let .deleteLocal(localHostId):
            try await sessionStore.deleteHost(id: localHostId)

        case let .updateRemoteCredentials(localHostId):
            try await credentialEngine.pushLocalCredential(hostId: localHostId)
        }
    }

}
