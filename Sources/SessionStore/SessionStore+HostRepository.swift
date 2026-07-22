import Combine
import Foundation
import HostRepositoryCore
import ServerSyncClient
import SSHCommandBuilder

extension SessionStore: HostRepository {
	public var hostSnapshot: [SSHHost] { hosts }
	public var localMutations: AnyPublisher<Void, Never> { mutationsForSync }

	public func createLocalHost(_ host: SSHHost) throws {
		try addHost(host)
	}

	public func updateLocalHostMetadata(_ host: SSHHost) throws {
		try updateHost(host)
	}

	public func deleteLocalHost(id: UUID) async throws {
		try await deleteHost(id: id)
	}

	public func pendingRemoteDeletionIDs() throws -> [String] {
		try pendingRemoteHostDeletionIDs()
	}

	public func recordPendingRemoteDeletion(serverID: String) throws {
		try recordPendingRemoteHostDeletion(serverID: serverID)
	}

	public func clearPendingRemoteDeletion(serverID: String) throws {
		try clearPendingRemoteHostDeletion(serverID: serverID)
	}

	public func createHostFromRemote(_ remote: RemoteHost) throws -> UUID {
		try addRemoteHost(remote)
	}

	public func updateHostFromRemote(localID: UUID, remote: RemoteHost) throws {
		try applyRemoteMetadata(localHostId: localID, remote: remote)
	}

	public func assignServerID(_ serverID: String, to localID: UUID) throws {
		try setServerId(serverID, for: localID)
	}

	public func markCredentialMaterialSynced(for localID: UUID) throws {
		try clearCredentialMaterialDirty(localID)
	}

	public func deleteHostFromRemote(localID: UUID) async throws {
		try await applyRemoteHostDeletion(id: localID)
	}
}
