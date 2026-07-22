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
