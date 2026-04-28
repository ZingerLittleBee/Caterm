import Combine
import Foundation
import ServerSyncClient
import SSHCommandBuilder
import SessionStore

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
    private let client: ServerSyncClient
    private let sessionStore: SessionStore
    private let authSession: AuthSessionProtocol
    private var cancellables: Set<AnyCancellable> = []
    private var inFlight: Task<Void, Error>?
    private var manualInProgress: Bool = false
    private var pendingAutoAfterManual: Bool = false
    private var currentManualTask: Task<Void, Error>?

    public init(client: ServerSyncClient,
                sessionStore: SessionStore,
                authSession: AuthSessionProtocol,
                debounceInterval: TimeInterval = 2.0) {
        self.client = client
        self.sessionStore = sessionStore
        self.authSession = authSession

        sessionStore.mutationsForSync
            .debounce(for: .seconds(debounceInterval),
                      scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.scheduleAutoSync() }
            .store(in: &cancellables)
    }

    // MARK: - Public entry points

    /// Manual entry point ("Sync Now" button — and any future caller).
    /// Throws on failure so the caller can display the error.
    public func sync() async throws {
        // Concurrent-manual lock + manual coordination land in Task 2.10.3d.
        // For now, behave like the original v1.1 entry point.
        try await performSync()
    }

    /// Startup entry point. No-op when signed out; otherwise schedule a sync.
    /// Synchronous (non-async) — the `.task` modifier wraps it; the actual
    /// sync work runs as an unstructured Task owned by HostSyncStore.
    public func syncIfSignedIn() {
        guard authSession.isSignedIn else { return }
        scheduleAutoSync()
    }

    // MARK: - Internal serialization

    /// Schedule a fire-and-forget auto sync. Manual-coordination gate
    /// lands in Task 2.10.3d; for 2.10.3a this just kicks off a Task.
    private func scheduleAutoSync() {
        // Chain serialization lands in Task 2.10.3c; for 2.10.3a we just
        // spawn an unobserved Task so syncIfSignedIn returns immediately.
        Task { [weak self] in
            guard let self else { return }
            try? await self.performSync()
        }
    }

    // MARK: - Sync work

    private func performSync() async throws {
        let remote = try await client.listHosts()
        let ops = HostSyncReconciler.reconcile(local: sessionStore.hosts,
                                                remote: remote)
        for op in ops {
            try await apply(op)
        }
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
