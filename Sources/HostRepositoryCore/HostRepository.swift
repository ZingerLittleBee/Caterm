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

	func prepare() async throws
	func createLocalHost(_ host: SSHHost) async throws
	func updateLocalHostMetadata(_ host: SSHHost) async throws
	func deleteLocalHost(id: UUID) async throws
	func pendingRemoteDeletionIDs() async throws -> [String]
	func recordPendingRemoteDeletion(serverID: String) async throws
	func clearPendingRemoteDeletion(serverID: String) async throws
	func createHostFromRemote(_ remote: RemoteHost) async throws -> UUID
	func updateHostFromRemote(localID: UUID, remote: RemoteHost) async throws
	func assignServerID(_ serverID: String, to localID: UUID) async throws
	func markCredentialMaterialSynced(for localID: UUID) async throws
	func deleteHostFromRemote(localID: UUID) async throws
}

public extension HostRepository {
	func prepare() async throws {}
}
