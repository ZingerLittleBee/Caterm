import Foundation
import ServerSyncClient
import SSHCommandBuilder

/// Pure Host metadata transformations shared by every platform adapter.
public enum HostRepositoryProjection {
	public static func inserting(
		_ remote: RemoteHost,
		localID: UUID = UUID(),
		into hosts: [SSHHost]
	) -> (hosts: [SSHHost], localID: UUID) {
		let host = SSHHost(
			id: localID,
			serverId: remote.id,
			name: remote.name,
			hostname: remote.hostname,
			port: remote.port,
			username: remote.username,
			credential: .password,
			createdAt: remote.createdAt,
			updatedAt: remote.updatedAt,
			jumpHostId: hosts.first(where: {
				$0.serverId == remote.jumpHostServerId
			})?.id,
			jumpHostServerId: remote.jumpHostServerId,
			forwards: remote.forwards,
			icon: remote.icon,
			organization: remote.organization,
			automation: remote.automation
		)
		var updated = hosts
		updated.append(host)
		for index in updated.indices where
			updated[index].jumpHostServerId == remote.id {
			updated[index].jumpHostId = localID
		}
		return (updated, localID)
	}

	public static func applying(
		_ remote: RemoteHost,
		to localID: UUID,
		in hosts: [SSHHost]
	) -> [SSHHost]? {
		guard let index = hosts.firstIndex(where: { $0.id == localID }) else {
			return nil
		}
		var updated = hosts
		updated[index].name = remote.name
		updated[index].hostname = remote.hostname
		updated[index].port = remote.port
		updated[index].username = remote.username
		updated[index].updatedAt = remote.updatedAt
		updated[index].jumpHostId = hosts.first(where: {
			$0.serverId == remote.jumpHostServerId
		})?.id
		updated[index].jumpHostServerId = remote.jumpHostServerId
		updated[index].forwards = remote.forwards
		updated[index].icon = remote.icon
		updated[index].organization = remote.organization
		updated[index].automation = remote.automation
		return updated
	}

	public static func assigning(
		serverID: String,
		to localID: UUID,
		in hosts: [SSHHost],
		at timestamp: Date = Date()
	) -> [SSHHost]? {
		guard let index = hosts.firstIndex(where: { $0.id == localID }) else {
			return nil
		}
		var updated = hosts
		updated[index].serverId = serverID
		updated[index].updatedAt = timestamp
		for childIndex in updated.indices where
			updated[childIndex].id != localID &&
			updated[childIndex].jumpHostId == localID &&
			updated[childIndex].jumpHostServerId != serverID {
			updated[childIndex].jumpHostServerId = serverID
			updated[childIndex].updatedAt = timestamp
		}
		return updated
	}
}
