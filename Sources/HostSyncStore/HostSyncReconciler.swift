import Foundation
import MergeDecision
import ServerSyncClient
import SSHCommandBuilder

/// Pure diff algorithm. Inputs are read-only; outputs are operations that
/// the caller will execute. Per spec §7.1.3, matching is by `serverId`,
/// conflicts resolve by `updatedAt` last-write-wins.
public enum HostSyncReconciler {
    public static func reconcileFullSnapshot(local: [SSHHost],
                                             remote: [RemoteHost]) -> [SyncOperation] {
        var ops: [SyncOperation] = []

        let remoteById = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        var matchedRemoteIds: Set<String> = []

        for localHost in local {
            if let serverId = localHost.serverId {
                if let r = remoteById[serverId] {
                    matchedRemoteIds.insert(serverId)
                    switch decision(local: localHost, incoming: r) {
                    case .incoming:
                        ops.append(.updateLocal(localHostId: localHost.id, remote: r))
                    case .local:
                        ops.append(.updateRemote(localHostId: localHost.id,
                                                  serverId: serverId))
                    case .equivalent:
                        break
                    }
                } else {
                    // Local thinks it's synced but server doesn't have it.
                    // Per spec: other device deleted it → delete locally.
                    ops.append(.deleteLocal(localHostId: localHost.id))
                }
            } else {
                // Brand-new local host → upload.
                ops.append(.createRemote(localHostId: localHost.id))
            }
        }

        // Anything in remote that wasn't matched is server-only → download.
        for r in remote where !matchedRemoteIds.contains(r.id) {
            ops.append(.createLocal(remote: r))
        }

        return ops
    }

    public static func reconcileDelta(
        local: [SSHHost],
        changedHosts: [RemoteHost],
        deletedHostIDs: [String]
    ) -> [SyncOperation] {
        var ops: [SyncOperation] = []
        let localIndex = MergeIdentityIndex(
            local,
            localID: { $0.id },
            serverID: { $0.serverId }
        )
        for r in changedHosts {
            if let existing = localIndex.match(
                localID: nil,
                serverID: r.id
            ) {
                switch decision(local: existing, incoming: r) {
                case .incoming:
                    ops.append(.updateLocal(localHostId: existing.id, remote: r))
                case .local:
                    ops.append(.updateRemote(localHostId: existing.id, serverId: r.id))
                case .equivalent:
                    break
                }
            } else {
                ops.append(.createLocal(remote: r))
            }
        }
        for id in deletedHostIDs {
            if let existing = localIndex.match(
                localID: nil,
                serverID: id
            ) {
                ops.append(.deleteLocal(localHostId: existing.id))
            }
        }
        return ops
    }

    private static func decision(
        local: SSHHost,
        incoming: RemoteHost
    ) -> MergeDecision {
        MergePolicy<SSHHost, RemoteHost>(
            local: { $0.updatedAt },
            incoming: { $0.updatedAt }
        )
        .resolvingTies { local, incoming in
            local.name != incoming.name
                || local.hostname != incoming.hostname
                || local.port != incoming.port
                || local.username != incoming.username
                || local.jumpHostServerId != incoming.jumpHostServerId
                || local.forwards != incoming.forwards
                || local.icon != incoming.icon
                ? .incoming
                : .equivalent
        }
        .decide(local: local, incoming: incoming)
    }
}
