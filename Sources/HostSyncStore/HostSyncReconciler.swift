import Foundation
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
                    if localHost.updatedAt < r.updatedAt {
                        ops.append(.updateLocal(localHostId: localHost.id, remote: r))
                    } else if localHost.updatedAt > r.updatedAt {
                        ops.append(.updateRemote(localHostId: localHost.id,
                                                  serverId: serverId))
                    } else if localHost.forwards != r.forwards {
                        // Equal updatedAt but forwards diverge — defensive
                        // catch for callers that mutated forwards without
                        // bumping updatedAt. Prefer the remote copy.
                        ops.append(.updateLocal(localHostId: localHost.id, remote: r))
                    }
                    // otherwise equal updatedAt → no-op
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
        let localByServerId = Dictionary(uniqueKeysWithValues:
            local.compactMap { h -> (String, SSHHost)? in
                guard let s = h.serverId else { return nil }
                return (s, h)
            }
        )
        for r in changedHosts {
            if let existing = localByServerId[r.id] {
                if existing.updatedAt < r.updatedAt {
                    ops.append(.updateLocal(localHostId: existing.id, remote: r))
                } else if existing.updatedAt > r.updatedAt {
                    ops.append(.updateRemote(localHostId: existing.id, serverId: r.id))
                } else if existing.forwards != r.forwards {
                    // Equal updatedAt but forwards diverge — defensive
                    // catch for callers that mutated forwards without
                    // bumping updatedAt. Prefer the remote copy.
                    ops.append(.updateLocal(localHostId: existing.id, remote: r))
                }
            } else {
                ops.append(.createLocal(remote: r))
            }
        }
        for id in deletedHostIDs {
            if let existing = localByServerId[id] {
                ops.append(.deleteLocal(localHostId: existing.id))
            }
        }
        return ops
    }
}
