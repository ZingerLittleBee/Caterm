import Combine
import Foundation
import HostRepositoryCore
import ServerSyncClient
import SSHCommandBuilder
import Testing

private struct TestCheckpoint: HostSyncCheckpoint {
	let id = UUID()
}

@MainActor
private final class DisappearingHostRepository: HostRepository {
	private let host: SSHHost
	private var snapshotReadCount = 0

	init(host: SSHHost) {
		self.host = host
	}

	var hostSnapshot: [SSHHost] {
		defer { snapshotReadCount += 1 }
		return snapshotReadCount == 0 ? [host] : []
	}

	var localMutations: AnyPublisher<Void, Never> {
		Empty().eraseToAnyPublisher()
	}

	func createLocalHost(_: SSHHost) throws {}
	func updateLocalHostMetadata(_: SSHHost) throws {}
	func deleteLocalHost(id _: UUID) async throws {}
	func pendingRemoteDeletionIDs() throws -> [String] { [] }
	func recordPendingRemoteDeletion(serverID _: String) throws {}
	func clearPendingRemoteDeletion(serverID _: String) throws {}
	func createHostFromRemote(_: RemoteHost) throws -> UUID { UUID() }
	func updateHostFromRemote(localID _: UUID, remote _: RemoteHost) throws {}
	func assignServerID(_: String, to _: UUID) throws {}
	func markCredentialMaterialSynced(for _: UUID) throws {}
	func deleteHostFromRemote(localID _: UUID) async throws {}
}

private final class RecordingSyncClient: IncrementalHostSyncClient, @unchecked Sendable {
	let checkpoint = TestCheckpoint()
	private(set) var createCallCount = 0
	private(set) var committedCheckpointIDs: [UUID] = []

	func listHosts() async throws -> [RemoteHost] { [] }

	func createHost(_: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput {
		createCallCount += 1
		return RemoteHostCreateOutput(id: "server-host")
	}

	func updateHost(_: RemoteHostUpdateInput) async throws {}
	func deleteHost(id _: String) async throws {}
	func preferredHostSyncMode() async -> HostSyncMode { .forceFull }
	func fetchHostChanges() async throws -> HostChangeBatch { batch(mode: .incremental) }
	func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch { batch(mode: .forceFull) }

	func commitHostCheckpoint(_ checkpoint: any HostSyncCheckpoint) async throws {
		committedCheckpointIDs.append(checkpoint.id)
	}

	func resetHostSyncState() async {}
	func ensureHostSubscription() async throws {}
	func deleteHostSubscription() async throws {}

	private func batch(mode: HostSyncMode) -> HostChangeBatch {
		HostChangeBatch(
			changedHosts: [],
			deletedHostIDs: [],
			checkpoint: checkpoint,
			tokenExpired: false,
			mode: mode
		)
	}
}

@MainActor
private final class PostCreateDeletingRepository: HostRepository {
	private var hosts: [SSHHost]
	private(set) var pendingDeletionIDs: [String] = []

	init(host: SSHHost) {
		hosts = [host]
	}

	var hostSnapshot: [SSHHost] { hosts }
	var localMutations: AnyPublisher<Void, Never> {
		Empty().eraseToAnyPublisher()
	}

	func removeHostDuringRemoteCreate() {
		hosts.removeAll()
	}

	func createLocalHost(_: SSHHost) throws {}
	func updateLocalHostMetadata(_: SSHHost) throws {}
	func deleteLocalHost(id _: UUID) async throws {}
	func pendingRemoteDeletionIDs() throws -> [String] { pendingDeletionIDs }
	func recordPendingRemoteDeletion(serverID: String) throws {
		pendingDeletionIDs.append(serverID)
	}
	func clearPendingRemoteDeletion(serverID _: String) throws {}
	func createHostFromRemote(_: RemoteHost) throws -> UUID { UUID() }
	func updateHostFromRemote(localID _: UUID, remote _: RemoteHost) throws {}
	func assignServerID(_: String, to localID: UUID) throws {
		guard hosts.contains(where: { $0.id == localID }) else {
			throw HostSynchronizationError.localHostMissing(localID)
		}
	}
	func markCredentialMaterialSynced(for _: UUID) throws {}
	func deleteHostFromRemote(localID _: UUID) async throws {}
}

private final class PostCreateDeletingClient: IncrementalHostSyncClient, @unchecked Sendable {
	let checkpoint = TestCheckpoint()
	private let onCreate: @Sendable () async -> Void
	private(set) var committedCheckpointIDs: [UUID] = []
	private(set) var deletedHostIDs: [String] = []
	var deletionError: (any Error)?

	init(onCreate: @escaping @Sendable () async -> Void) {
		self.onCreate = onCreate
	}

	func listHosts() async throws -> [RemoteHost] { [] }
	func createHost(_: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput {
		await onCreate()
		return RemoteHostCreateOutput(id: "server-host")
	}
	func updateHost(_: RemoteHostUpdateInput) async throws {}
	func deleteHost(id: String) async throws {
		if let deletionError { throw deletionError }
		deletedHostIDs.append(id)
	}
	func preferredHostSyncMode() async -> HostSyncMode { .forceFull }
	func fetchHostChanges() async throws -> HostChangeBatch { batch(mode: .incremental) }
	func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch { batch(mode: .forceFull) }
	func commitHostCheckpoint(_ checkpoint: any HostSyncCheckpoint) async throws {
		committedCheckpointIDs.append(checkpoint.id)
	}
	func resetHostSyncState() async {}
	func ensureHostSubscription() async throws {}
	func deleteHostSubscription() async throws {}

	private func batch(mode: HostSyncMode) -> HostChangeBatch {
		HostChangeBatch(
			changedHosts: [],
			deletedHostIDs: [],
			checkpoint: checkpoint,
			tokenExpired: false,
			mode: mode
		)
	}
}

@Test("A missing planned local Host aborts before checkpoint commit")
@MainActor
private func missingPlannedLocalHostAbortsCheckpoint() async throws {
	let host = SSHHost(
		name: "Production",
		hostname: "prod.example.com",
		username: "deploy",
		credential: .agent
	)
	let repository = DisappearingHostRepository(host: host)
	let client = RecordingSyncClient()

	await #expect(throws: HostSynchronizationError.localHostMissing(host.id)) {
		try await HostSynchronization.synchronize(
			repository: repository,
			client: client,
			mode: .forceFull
		)
	}
	#expect(client.createCallCount == 0)
	#expect(client.committedCheckpointIDs.isEmpty)
}

@Test("A failed compensation records the orphaned remote Host for deletion")
@MainActor
private func failedRemoteCreateCompensationPersistsDeletionIntent() async throws {
	enum Failure: Error { case offline }
	let host = SSHHost(
		name: "Production",
		hostname: "prod.example.com",
		username: "deploy",
		credential: .agent
	)
	let repository = PostCreateDeletingRepository(host: host)
	let client = PostCreateDeletingClient {
		await repository.removeHostDuringRemoteCreate()
	}
	client.deletionError = Failure.offline

	await #expect(throws: HostSynchronizationError.localHostMissing(host.id)) {
		try await HostSynchronization.synchronize(
			repository: repository,
			client: client,
			mode: .forceFull
		)
	}
	#expect(client.committedCheckpointIDs.isEmpty)
	#expect(try repository.pendingRemoteDeletionIDs() == ["server-host"])
}

@Test("A Host removed during remote creation does not commit the checkpoint")
@MainActor
private func removedHostAfterRemoteCreateAbortsCheckpoint() async throws {
	let host = SSHHost(
		name: "Production",
		hostname: "prod.example.com",
		username: "deploy",
		credential: .agent
	)
	let repository = PostCreateDeletingRepository(host: host)
	let client = PostCreateDeletingClient {
		await repository.removeHostDuringRemoteCreate()
	}

	await #expect(throws: HostSynchronizationError.localHostMissing(host.id)) {
		try await HostSynchronization.synchronize(
			repository: repository,
			client: client,
			mode: .forceFull
		)
	}
	#expect(client.committedCheckpointIDs.isEmpty)
	#expect(client.deletedHostIDs == ["server-host"])
	#expect(try repository.pendingRemoteDeletionIDs().isEmpty)
}
