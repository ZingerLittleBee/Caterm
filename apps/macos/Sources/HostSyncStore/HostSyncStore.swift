import AppKit
import Combine
import CredentialSyncStore
import CredentialSyncTypes
import CryptoKit
import Foundation
import KeychainStore
import ManagedKeyStore
import ServerSyncClient
import SSHCommandBuilder
import SessionStore
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
/// **Thread model:** `@MainActor` throughout. All `inFlight` /
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
    private let credentialSync: CredentialSyncPreferencesStore
    private let masterKeyStore: KeychainSyncMasterKeyStore
    private let managedKeyStore: ManagedKeyStore
    private let userDefaults: UserDefaults

    #if DEBUG
    /// Test-only seam: mirrors the ops applied during the most recent
    /// `performSync()` cycle. Reset at the start of the op-loop and
    /// appended to as each op is dispatched.
    internal private(set) var lastAppliedOpsForTesting: [SyncOperation] = []
    /// Test-only seam (Plan C / Task 16): records every invocation of
    /// `decryptAndApply`. Task 17 will fill the body — Task 16's tests use
    /// this counter to verify the `.enabled` + `.payload` dispatch path
    /// reaches the decrypt step.
    internal private(set) var decryptAndApplyInvocations: [(localHostId: UUID, revision: Int64)] = []
    #endif
    /// The view layer reads the same threshold used by failure detection.
    public let periodicInterval: TimeInterval
    private var cancellables: Set<AnyCancellable> = []
    private var periodicTimerCancellable: AnyCancellable?
    private var inFlight: Task<Void, Error>?
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
    /// Generation token gating the single isSyncing-clear site in startSync().
    /// Each call to startSync() captures a snapshot; only the latest
    /// generation's defer is permitted to clear isSyncing — preserves the
    /// flag across chained cancel-and-drain handoffs (spec §2.1.2 / Decision #22).
    private var syncGeneration: Int = 0

    /// "Last fully-applied sync." Set after performSync() completes the op
    /// loop without throwing. NOT updated when fetch fails or any
    /// apply(op) throws — see spec §4.2.
    @Published public private(set) var lastSyncedAt: Date?
    @Published public private(set) var lastSyncAttemptedAt: Date?
    @Published public private(set) var lastSyncErrorKind: SyncErrorKind?
    @Published public private(set) var failingSince: Date?
    @Published public private(set) var isSyncing: Bool = false

    /// Computed proxy so SwiftUI views can read sign-in state without holding
    /// a direct AuthSession reference (AuthSession is not ObservableObject).
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
                managedKeyStore: ManagedKeyStore = ManagedKeyStore(),
                debounceInterval: TimeInterval = 2.0,
                periodicInterval: TimeInterval = 60 * 60,
                userDefaults: UserDefaults = .standard,
                notificationCenter: NotificationDelivering = LiveNotificationCenter()) {
        self.client = client
        self.sessionStore = sessionStore
        self.authSession = authSession
        self.preferences = preferences
        self.credentialSync = credentialSync
        self.masterKeyStore = masterKeyStore
        self.managedKeyStore = managedKeyStore
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
            .sink { [weak self] _ in self?.scheduleAutoSync(mode: .auto) }
            .store(in: &cancellables)
    }

    // MARK: - Public entry points

    /// Manual entry point ("Sync Now" button — and any future caller).
    /// Concurrent callers share the in-flight task's outcome instead of
    /// starting a second pass, so the public API is safe to call without
    /// external `disabled(isSyncing)`-style guards.
    public func sync() async throws {
        if let existing = currentManualTask {
            try await existing.value
            return
        }
        let task = Task<Void, Error> { [self] in
            manualInProgress = true
            defer {
                manualInProgress = false
                currentManualTask = nil
                if pendingAutoAfterManual {
                    pendingAutoAfterManual = false
                    scheduleAutoSync()
                }
            }
            try await startSync().value
        }
        currentManualTask = task
        try await task.value
    }

    /// Startup entry point. No-op when signed out; otherwise schedule a sync.
    /// Synchronous (non-async) — the `.task` modifier wraps it; the actual
    /// sync work runs as an unstructured Task owned by HostSyncStore.
    public func syncIfSignedIn() {
        guard authSession.isSignedIn else { return }
        scheduleAutoSync()
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

    /// Append a new sync onto the serialized chain. The new task cancels
    /// the previous one and waits for it to fully exit (drain) before
    /// running its own work — guarantees mutual exclusion across
    /// consecutive sync passes.
    @discardableResult
    private func startSync(mode: SyncMode = .auto) -> Task<Void, Error> {
        let prev = inFlight
        syncGeneration += 1
        let myGeneration = syncGeneration
        isSyncing = true
        let new = Task { [weak self] in
            guard let self else { return }
            defer {
                // The MainActor dispatch may itself race a third startSync()
                // call landing between this defer firing and the inner Task
                // running — that is safe because syncGeneration is re-read
                // here, after dispatch, and the gate skips clear when an
                // even-newer generation has taken over.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Only the latest startSync() generation may clear the flag.
                    // An older task draining after being cancelled must not
                    // toggle isSyncing while a newer task is still running
                    // (spec Decision #22).
                    if self.syncGeneration == myGeneration {
                        self.isSyncing = false
                    }
                }
            }
            prev?.cancel()
            _ = await prev?.result   // drain — always resolves (success / throw / CancellationError)
            try Task.checkCancellation()  // we may have been replaced too
            try await self.performSync(mode: mode)
        }
        inFlight = new
        return new
    }

    // MARK: - Sync work

    private func performSync(mode requestedMode: SyncMode = .auto) async throws {
        let failureStateToken = failureStateResetToken
        let attempted = Date()
        lastSyncAttemptedAt = attempted
        userDefaults.set(attempted, forKey: Self.lastSyncAttemptedAtKey)

        do {
            let effectiveMode: HostSyncMode
            switch requestedMode {
            case .auto:        effectiveMode = await client.preferredHostSyncMode()
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
            // Plan C — cycle-start dirty scan. After the reconciler emits its
            // metadata ops, append `.updateRemoteCredentials` for any locally
            // dirty host, gated on prefs.state == .enabled and no destructive
            // deletion in progress. The executor body lives in Task 14.
            var allOps = ops
            let prefs = credentialSync.prefs
            if prefs.deleteCredentialsFromCloudInProgress == nil,
               case .enabled = prefs.state {
                for host in sessionStore.hosts where host.credentialMaterialDirty {
                    allOps.append(.updateRemoteCredentials(localHostId: host.id))
                }
            }

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
                port: host.port, username: host.username
            )
            let out = try await client.createHost(input)
            try sessionStore.setServerId(out.id, for: localHostId)

        case let .createLocal(remote):
            try sessionStore.addRemoteHost(remote)
            // Plan C / Task 16 — if the snapshot carried a credential blob
            // for this remote, run it through the pull-side state machine.
            // `addRemoteHost` allocates a fresh local UUID; look it up by
            // serverId rather than mutating addRemoteHost's signature.
            if let blob = credentialBlobs[remote.id],
               let local = sessionStore.hosts.last(where: { $0.serverId == remote.id }) {
                try await applyCredentialBlobOnPull(
                    localHostId: local.id, remote: remote, blob: blob
                )
            }

        case let .updateRemote(localHostId, serverId):
            guard let host = sessionStore.hosts.first(where: { $0.id == localHostId }) else { return }
            let input = RemoteHostUpdateInput(
                id: serverId, name: host.name, hostname: host.hostname,
                port: host.port, username: host.username
            )
            try await client.updateHost(input)

        case let .updateLocal(localHostId, remote):
            try sessionStore.applyRemoteMetadata(localHostId: localHostId, remote: remote)
            if let blob = credentialBlobs[remote.id] {
                try await applyCredentialBlobOnPull(
                    localHostId: localHostId, remote: remote, blob: blob
                )
            }

        case let .deleteLocal(localHostId):
            try sessionStore.deleteHost(id: localHostId)

        case let .updateRemoteCredentials(localHostId):
            try await applyUpdateRemoteCredentials(localHostId: localHostId)
        }
    }

    /// Plan C / Task 16 — pull-side credential state machine.
    ///
    /// Dispatches a freshly-fetched `CredentialBlob` through the four
    /// `CredentialSyncState` arms. The actual decrypt + apply path
    /// (`.enabled` + `.payload`) is filled by Task 17; here we only
    /// stub `decryptAndApply` so the dispatch logic is testable now.
    ///
    /// Stale-revision drop: if `blob.revision <= lastAppliedRevision[hostId]`,
    /// return immediately. This guards against re-applying a previously
    /// processed blob when the same record arrives again (forceFull rebuild,
    /// duplicate notification, etc.).
    private func applyCredentialBlobOnPull(
        localHostId: UUID,
        remote: RemoteHost,
        blob: CredentialBlob
    ) async throws {
        let lastApplied = credentialSync.prefs.lastAppliedRevision[localHostId] ?? 0
        if blob.revision <= lastApplied { return }

        switch credentialSync.prefs.state {
        case .disabled:
            // Drop. Do NOT advance lastAppliedRevision — re-enabling later
            // must replay this blob.
            return

        case .pausedByRemote(let seenTombstoneRev):
            // We're paused because of an earlier tombstone. A newer payload
            // bumps the tombstone-rev marker (so a later "resume" knows the
            // observed high-water mark), but we still don't apply.
            if blob.state == .payload && blob.revision > seenTombstoneRev {
                credentialSync.mutate {
                    $0.state = .pausedByRemote(seenTombstoneRevision: blob.revision)
                }
            }
            return

        case .waitingForKey:
            switch blob.state {
            case .payload:
                credentialSync.mutate {
                    $0.state = .waitingForKey(observedKeyID: blob.keyID)
                }
            case .tombstone:
                credentialSync.mutate {
                    $0.state = .pausedByRemote(seenTombstoneRevision: blob.revision)
                }
            case .none:
                return
            }
            return

        case .enabled:
            switch blob.state {
            case .tombstone:
                credentialSync.mutate {
                    $0.state = .pausedByRemote(seenTombstoneRevision: blob.revision)
                    $0.lastAppliedRevision[localHostId] = blob.revision
                }
                return
            case .none:
                credentialSync.mutate {
                    $0.lastAppliedRevision[localHostId] = blob.revision
                }
                return
            case .payload:
                try await decryptAndApply(
                    localHostId: localHostId, remote: remote, blob: blob
                )
            }
        }
    }

    /// Plan C / Task 17 stub. The real implementation will:
    ///   1. Look up the master key for `blob.keyID` in the iCloud-Keychain-
    ///      backed master-key store. If missing, transition state to
    ///      `.waitingForKey(observedKeyID: blob.keyID)` and return.
    ///   2. Decrypt the three field ciphertexts with envelope AAD, write
    ///      private-key bytes via ManagedKeyStore, then call
    ///      `sessionStore.applyRemoteCredential(...)`.
    ///   3. On success, bump `lastAppliedRevision[hostId] = blob.revision`.
    ///
    /// For Task 16 we only need to record that this dispatch path was
    /// reached so tests can verify the state-machine routing. The body is a
    /// no-op so tests don't need to handle a thrown error from a path that's
    /// expected to succeed.
    private func decryptAndApply(
        localHostId: UUID,
        remote _: RemoteHost,
        blob: CredentialBlob
    ) async throws {
        #if DEBUG
        decryptAndApplyInvocations.append(
            (localHostId: localHostId, revision: blob.revision)
        )
        #endif
        // Task 17 will replace this stub.
    }

    /// Plan C — push the local encrypted credential blob to CloudKit for
    /// `localHostId`.
    ///
    /// Bail (no-op) when:
    /// - host has no `serverId` yet (createRemote in this cycle hasn't run / failed)
    /// - prefs.state is not `.enabled` (defensive — caller already gated)
    /// - master key is absent from the keychain (iCloud Keychain hasn't yet
    ///   delivered it on this device); the dirty bit stays set so a later
    ///   cycle can retry
    ///
    /// On push success: bumps `prefs.lastAppliedRevision[hostId]` and clears
    /// the host's `credentialMaterialDirty`. Push failure propagates to the
    /// sync cycle (commit is skipped, dirty stays).
    private func applyUpdateRemoteCredentials(localHostId: UUID) async throws {
        guard let host = sessionStore.hosts.first(where: { $0.id == localHostId }) else { return }
        guard let serverId = host.serverId else { return }
        guard case .enabled = credentialSync.prefs.state else { return }
        guard let resolved = await masterKeyStore.loadAny() else { return }
        let masterKey = resolved.key
        let keyID = resolved.keyID

        let pwSecret: Data? = (try? sessionStore.keychain.get(account: "\(localHostId.uuidString).password"))
            .flatMap { $0.data(using: .utf8) }
        let ppSecret: Data? = (try? sessionStore.keychain.get(account: "\(localHostId.uuidString).keyPassphrase"))
            .flatMap { $0.data(using: .utf8) }

        let pkBytes: Data?
        if case let .keyFile(path, _) = host.credential {
            if let managed = (try? managedKeyStore.read(hostId: localHostId)) ?? nil {
                pkBytes = managed
            } else {
                pkBytes = FileManager.default.contents(atPath: path)
            }
        } else {
            pkBytes = nil
        }

        let nextRev = (credentialSync.prefs.lastAppliedRevision[localHostId] ?? 0) + 1
        let aadFor: (FieldKind) -> Data = { kind in
            EnvelopeCrypto.aad(serverId: serverId, fieldKind: kind, revision: nextRev)
        }
        let blob = CredentialBlob(
            state: .payload,
            revision: nextRev,
            keyID: keyID,
            cryptoVersion: Int64(EnvelopeCrypto.schemaVersion),
            passwordCiphertext: try pwSecret.map { try EnvelopeCrypto.seal($0, key: masterKey, aad: aadFor(.password)) },
            passphraseCiphertext: try ppSecret.map { try EnvelopeCrypto.seal($0, key: masterKey, aad: aadFor(.passphrase)) },
            privateKeyCiphertext: try pkBytes.map { try EnvelopeCrypto.seal($0, key: masterKey, aad: aadFor(.privateKey)) }
        )
        let pushedRev = try await client.pushHostCredentialBlob(serverId: serverId, blob: blob)
        credentialSync.mutate { $0.lastAppliedRevision[localHostId] = pushedRev }
        try sessionStore.clearCredentialMaterialDirty(localHostId)
    }
}
