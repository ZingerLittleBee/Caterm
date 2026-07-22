import CatermMobile
import Foundation
import HostRepositoryCore
import KeychainStore
import ServerSyncClient
import SessionStore
import SSHCommandBuilder
import Testing

private final class SharedSyncClient: IncrementalHostSyncClient, @unchecked Sendable {
	var listResult: [RemoteHost] = []
	var createResult = RemoteHostCreateOutput(id: "server-created")
	private(set) var createdHostNames: [String] = []
	private(set) var updatedHostIDs: [String] = []
	private(set) var deletedHostIDs: [String] = []

	func listHosts() async throws -> [RemoteHost] { listResult }
	func createHost(_ input: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput {
		createdHostNames.append(input.name)
		return createResult
	}
	func updateHost(_ input: RemoteHostUpdateInput) async throws {
		updatedHostIDs.append(input.id)
	}
	func deleteHost(id: String) async throws {
		deletedHostIDs.append(id)
	}
	func preferredHostSyncMode() async -> HostSyncMode { .forceFull }
	func fetchHostChanges() async throws -> HostChangeBatch {
		HostChangeBatch(
			changedHosts: [],
			deletedHostIDs: [],
			checkpoint: nil,
			tokenExpired: false,
			mode: .incremental
		)
	}
	func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch {
		HostChangeBatch(
			changedHosts: listResult,
			deletedHostIDs: [],
			checkpoint: nil,
			tokenExpired: false,
			mode: .forceFull
		)
	}
	func commitHostCheckpoint(_: any HostSyncCheckpoint) async throws {}
	func resetHostSyncState() async {}
	func ensureHostSubscription() async throws {}
	func deleteHostSubscription() async throws {}
}

private enum SharedHostRepositoryPlatform: Sendable {
	case macOS
	case iOS
}

private struct SharedHostState: Equatable {
	let serverID: String?
	let name: String
	let hostname: String
	let credentialMaterialDirty: Bool
}

private struct SharedSyncOutcome: Equatable {
	let operations: [SyncOperation]
	let hosts: [SharedHostState]
	let createdHostNames: [String]
	let updatedHostIDs: [String]
	let deletedHostIDs: [String]
	let pendingDeletionIDs: [String]
	let credentialHookHostIDs: [UUID]
}

@MainActor
private func makeSharedSyncRepository(
	for platform: SharedHostRepositoryPlatform,
	fileURL: URL
) -> any HostRepository {
	switch platform {
	case .macOS:
		return SessionStore(
			askpassPath: "/x",
			knownHostsCaterm: "/A",
			knownHostsUser: "/B",
			accessGroup: nil,
			hostsURL: fileURL,
			keychain: KeychainStore(
				service: "com.caterm.test.\(UUID().uuidString)",
				accessGroup: nil
			)
		)
	case .iOS:
		return MobileHostStore(fileURL: fileURL)
	}
}

@Test("Shared synchronization produces identical complete outcomes")
@MainActor
private func sharedSynchronizationProducesIdenticalCompleteOutcomes() async throws {
	let macOS = try await runSharedSyncScenario(on: .macOS)
	let iOS = try await runSharedSyncScenario(on: .iOS)

	#expect(macOS == iOS)
	#expect(macOS.operations.count == 6)
	#expect(macOS.createdHostNames == ["local-create"])
	#expect(macOS.updatedHostIDs == ["server-push"])
	#expect(macOS.deletedHostIDs == ["server-tombstone"])
	#expect(macOS.pendingDeletionIDs.isEmpty)
	#expect(macOS.hosts.map(\.serverID) == [
		"server-created",
		"server-pull",
		"server-push",
		"server-remote"
	])
}

@MainActor
private func runSharedSyncScenario(
	on platform: SharedHostRepositoryPlatform
) async throws -> SharedSyncOutcome {
	let fileURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("shared-host-sync-\(UUID().uuidString).json")
	let deletionURL = fileURL.deletingPathExtension()
		.appendingPathExtension("deletions.json")
	defer {
		try? FileManager.default.removeItem(at: fileURL)
		try? FileManager.default.removeItem(at: deletionURL)
	}
	let repository = makeSharedSyncRepository(for: platform, fileURL: fileURL)
	let old = Date(timeIntervalSince1970: 1_700_000_000)
	let new = old.addingTimeInterval(60)
	let localCreate = SSHHost(
		id: stableID(41),
		name: "local-create",
		hostname: "create.example.com",
		username: "deploy",
		credential: .agent,
		createdAt: old,
		updatedAt: old
	)
	let localPush = SSHHost(
		id: stableID(42),
		serverId: "server-push",
		name: "local-push",
		hostname: "push.example.com",
		username: "deploy",
		credential: .password,
		createdAt: old,
		updatedAt: new,
		credentialMaterialDirty: true
	)
	let localPull = SSHHost(
		id: stableID(43),
		serverId: "server-pull",
		name: "local-pull",
		hostname: "old-pull.example.com",
		username: "deploy",
		credential: .keyFile(keyPath: "/device/key", hasPassphrase: true),
		createdAt: old,
		updatedAt: old,
		credentialMaterialDirty: true
	)
	let localDelete = SSHHost(
		id: stableID(44),
		serverId: "server-missing",
		name: "local-delete",
		hostname: "delete.example.com",
		username: "deploy",
		credential: .agent,
		createdAt: old,
		updatedAt: old
	)
	let tombstone = SSHHost(
		id: stableID(45),
		serverId: "server-tombstone",
		name: "local-tombstone",
		hostname: "tombstone.example.com",
		username: "deploy",
		credential: .agent,
		createdAt: old,
		updatedAt: old
	)
	for host in [localCreate, localPush, localPull, localDelete, tombstone] {
		try repository.createLocalHost(host)
	}
	try await repository.deleteLocalHost(id: tombstone.id)

	let client = SharedSyncClient()
	client.listResult = [
		RemoteHost(
			id: "server-push",
			name: "remote-old-push",
			hostname: "old-push.example.com",
			port: 22,
			username: "deploy",
			authType: "password",
			createdAt: old,
			updatedAt: old
		),
		RemoteHost(
			id: "server-pull",
			name: "remote-pull",
			hostname: "pull.example.com",
			port: 2222,
			username: "operator",
			authType: "password",
			createdAt: old,
			updatedAt: new
		),
		RemoteHost(
			id: "server-remote",
			name: "remote-create",
			hostname: "remote.example.com",
			port: 22,
			username: "deploy",
			authType: "password",
			createdAt: old,
			updatedAt: old
		)
	]
	var credentialHookHostIDs: [UUID] = []

	let operations = try await HostSynchronization.synchronize(
		repository: repository,
		client: client,
		mode: .forceFull,
		additionalOperations: [
			.updateRemoteCredentials(localHostId: localPush.id)
		],
		afterApply: { operation, _ in
			if case let .updateRemoteCredentials(localHostID) = operation {
				credentialHookHostIDs.append(localHostID)
			}
		}
	)

	let hosts = repository.hostSnapshot
		.map {
			SharedHostState(
				serverID: $0.serverId,
				name: $0.name,
				hostname: $0.hostname,
				credentialMaterialDirty: $0.credentialMaterialDirty
			)
		}
		.sorted { ($0.serverID ?? "") < ($1.serverID ?? "") }
	return SharedSyncOutcome(
		operations: operations,
		hosts: hosts,
		createdHostNames: client.createdHostNames,
		updatedHostIDs: client.updatedHostIDs,
		deletedHostIDs: client.deletedHostIDs,
		pendingDeletionIDs: try repository.pendingRemoteDeletionIDs(),
		credentialHookHostIDs: credentialHookHostIDs
	)
}

private func stableID(_ suffix: Int) -> UUID {
	UUID(uuidString: String(
		format: "00000000-0000-0000-0000-%012d",
		suffix
	))!
}
