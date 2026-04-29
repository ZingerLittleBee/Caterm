import AppKit
import Combine
import Foundation
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
        try await UNUserNotificationCenter.current().add(request)
    }
}

/// Derives user-visible sync failure state from timestamps.
///
/// The threshold is based on `now - lastSyncedAt`; returned `.failing(... since:)`
/// uses `lastSyncAttemptedAt`. Store-level `failingSince` is handled separately.
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
    guard let succeeded = lastSyncedAt else { return .normal }
    guard attempted > succeeded else { return .normal }
    guard now.timeIntervalSince(succeeded) > failingThreshold else { return .normal }
    let reason = lastSyncErrorKind ?? .other
    return .failing(reason: reason, since: attempted)
}

/// Coordinates sync passes: list remote → reconcile → apply ops.
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

    private let client: ServerSyncClient
    private let sessionStore: SessionStore
    private let authSession: AuthSessionProtocol
    private let preferences: SyncPreferences
    private let userDefaults: UserDefaults
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
    /// loop without throwing. NOT updated when listHosts fails or any
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

    public init(client: ServerSyncClient,
                sessionStore: SessionStore,
                authSession: AuthSessionProtocol,
                preferences: SyncPreferences,
                debounceInterval: TimeInterval = 2.0,
                periodicInterval: TimeInterval = 15 * 60,
                userDefaults: UserDefaults = .standard,
                notificationCenter: NotificationDelivering = LiveNotificationCenter()) {
        self.client = client
        self.sessionStore = sessionStore
        self.authSession = authSession
        self.preferences = preferences
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
    private func scheduleAutoSync() {
        guard authSession.isSignedIn else { return }
        guard !manualInProgress else {
            pendingAutoAfterManual = true
            return
        }
        _ = startSync()
    }

    /// Start (or stop) the 15-minute periodic timer based on the user's
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
            .sink { [weak self] _ in self?.scheduleAutoSync() }
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
    private func startSync() -> Task<Void, Error> {
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
            try await self.performSync()
        }
        inFlight = new
        return new
    }

    // MARK: - Sync work

    private func performSync() async throws {
        let failureStateToken = failureStateResetToken
        let attempted = Date()
        lastSyncAttemptedAt = attempted
        userDefaults.set(attempted, forKey: Self.lastSyncAttemptedAtKey)

        do {
            let remote = try await client.listHosts()
            try Task.checkCancellation()
            let ops = HostSyncReconciler.reconcile(local: sessionStore.hosts,
                                                    remote: remote)
            for op in ops {
                try Task.checkCancellation()
                try await apply(op)
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

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return Task.isCancelled
    }

    private func classifySyncError(_ error: Error) -> SyncErrorKind {
        guard let serverError = error as? ServerSyncError else { return .other }
        switch serverError {
        case .http(status: 401, body: _),
             .orpc(code: _, status: 401, message: _),
             .authFailed,
             .notSignedIn:
            return .auth
        case .http,
             .orpc,
             .decode:
            return .other
        }
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

    private func apply(_ op: SyncOperation) async throws {
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

        case let .updateRemote(localHostId, serverId):
            guard let host = sessionStore.hosts.first(where: { $0.id == localHostId }) else { return }
            let input = RemoteHostUpdateInput(
                id: serverId, name: host.name, hostname: host.hostname,
                port: host.port, username: host.username
            )
            try await client.updateHost(input)

        case let .updateLocal(localHostId, remote):
            try sessionStore.applyRemoteMetadata(localHostId: localHostId, remote: remote)

        case let .deleteLocal(localHostId):
            try sessionStore.deleteHost(id: localHostId)
        }
    }
}
