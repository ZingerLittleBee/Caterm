import MergeDecision
import ServerSyncClient
import SSHCommandBuilder

public enum HostSyncReconciler {
	public static func reconcileFullSnapshot(
		local: [SSHHost],
		remote: [RemoteHost]
	) -> [SyncOperation] {
		var operations: [SyncOperation] = []
		let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
		var matchedRemoteIDs: Set<String> = []

		for localHost in local {
			guard let serverID = localHost.serverId else {
				operations.append(.createRemote(localHostId: localHost.id))
				continue
			}
			guard let remoteHost = remoteByID[serverID] else {
				operations.append(.deleteLocal(localHostId: localHost.id))
				continue
			}
			matchedRemoteIDs.insert(serverID)
			switch decision(local: localHost, incoming: remoteHost) {
			case .incoming:
				operations.append(.updateLocal(
					localHostId: localHost.id,
					remote: remoteHost
				))
			case .local:
				operations.append(.updateRemote(
					localHostId: localHost.id,
					serverId: serverID
				))
			case .equivalent:
				break
			}
		}

		for remoteHost in remote where !matchedRemoteIDs.contains(remoteHost.id) {
			operations.append(.createLocal(remote: remoteHost))
		}
		return operations
	}

	public static func reconcileDelta(
		local: [SSHHost],
		changedHosts: [RemoteHost],
		deletedHostIDs: [String]
	) -> [SyncOperation] {
		var operations: [SyncOperation] = []
		let localIndex = MergeIdentityIndex(
			local,
			localID: { $0.id },
			serverID: { $0.serverId }
		)
		for remoteHost in changedHosts {
			guard let existing = localIndex.match(
				localID: nil,
				serverID: remoteHost.id
			) else {
				operations.append(.createLocal(remote: remoteHost))
				continue
			}
			switch decision(local: existing, incoming: remoteHost) {
			case .incoming:
				operations.append(.updateLocal(
					localHostId: existing.id,
					remote: remoteHost
				))
			case .local:
				operations.append(.updateRemote(
					localHostId: existing.id,
					serverId: remoteHost.id
				))
			case .equivalent:
				break
			}
		}
		for serverID in deletedHostIDs {
			if let existing = localIndex.match(localID: nil, serverID: serverID) {
				operations.append(.deleteLocal(localHostId: existing.id))
			}
		}
		return operations
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
				|| local.organization != incoming.organization
				? .incoming
				: .equivalent
		}
		.decide(local: local, incoming: incoming)
	}
}
