import Combine
import Foundation
import HostRepositoryCore
import ServerSyncClient
import SSHCommandBuilder

extension SessionStore: HostRepository {
	public var hostSnapshot: [SSHHost] { hosts }
	public var localMutations: AnyPublisher<Void, Never> { mutationsForSync }

	public func prepare() async throws {
		try await prepareHostRepository()
	}

	public func createLocalHost(_ host: SSHHost) async throws {
		try await addHost(host)
	}

	public func updateLocalHostMetadata(_ host: SSHHost) async throws {
		try await updateHost(host)
	}

	public func deleteLocalHost(id: UUID) async throws {
		try await deleteHost(id: id)
	}

	public func pendingRemoteDeletionIDs() async throws -> [String] {
		try await pendingRemoteHostDeletionIDs()
	}

	public func recordPendingRemoteDeletion(serverID: String) async throws {
		try await recordPendingRemoteHostDeletion(serverID: serverID)
	}

	public func clearPendingRemoteDeletion(serverID: String) async throws {
		try await clearPendingRemoteHostDeletion(serverID: serverID)
	}

	public func createHostFromRemote(_ remote: RemoteHost) async throws -> UUID {
		try await addRemoteHost(remote)
	}

	public func updateHostFromRemote(localID: UUID, remote: RemoteHost) async throws {
		try await applyRemoteMetadata(localHostId: localID, remote: remote)
	}

	public func assignServerID(_ serverID: String, to localID: UUID) async throws {
		try await setServerId(serverID, for: localID)
	}

	public func markCredentialMaterialSynced(for localID: UUID) async throws {
		try await clearCredentialMaterialDirty(localID)
	}

	public func deleteHostFromRemote(localID: UUID) async throws {
		try await applyRemoteHostDeletion(id: localID)
	}
}
