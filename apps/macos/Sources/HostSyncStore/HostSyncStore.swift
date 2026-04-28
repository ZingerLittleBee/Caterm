import Foundation
import ServerSyncClient
import SSHCommandBuilder
import SessionStore

/// Coordinates a single sync pass: list remote → reconcile → apply ops.
@MainActor
public final class HostSyncStore {
    private let client: ServerSyncClient
    private let sessionStore: SessionStore

    public init(client: ServerSyncClient, sessionStore: SessionStore) {
        self.client = client
        self.sessionStore = sessionStore
    }

    public func sync() async throws {
        let remote = try await client.listHosts()
        let ops = HostSyncReconciler.reconcile(local: sessionStore.hosts,
                                                remote: remote)
        for op in ops {
            try await apply(op)
        }
    }

    private func apply(_ op: SyncOperation) async throws {
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
