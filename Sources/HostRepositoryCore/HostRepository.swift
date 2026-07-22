import Combine
import Foundation
import ServerSyncClient
import SSHCommandBuilder

/// Platform-neutral persistence boundary for saved Hosts.
///
/// Platform stores remain responsible for UI observation and credential
/// material. Synchronization consumes this contract instead of a terminal
/// session store.
@MainActor
public protocol HostRepository: AnyObject {
	var hostSnapshot: [SSHHost] { get }
	var localMutations: AnyPublisher<Void, Never> { get }

	func createLocalHost(_ host: SSHHost) throws
	func updateLocalHostMetadata(_ host: SSHHost) throws
	func deleteLocalHost(id: UUID) async throws
	func pendingRemoteDeletionIDs() throws -> [String]
	func recordPendingRemoteDeletion(serverID: String) throws
	func clearPendingRemoteDeletion(serverID: String) throws
	func createHostFromRemote(_ remote: RemoteHost) throws -> UUID
	func updateHostFromRemote(localID: UUID, remote: RemoteHost) throws
	func assignServerID(_ serverID: String, to localID: UUID) throws
	func markCredentialMaterialSynced(for localID: UUID) throws
	func deleteHostFromRemote(localID: UUID) async throws
}
