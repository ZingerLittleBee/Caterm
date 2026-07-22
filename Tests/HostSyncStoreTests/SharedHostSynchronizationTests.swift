import CatermMobile
import Foundation
import HostRepositoryCore
import KeychainStore
import ServerSyncClient
import SessionStore
import SSHCommandBuilder
import Testing

private enum SharedHostRepositoryPlatform: Sendable {
	case macOS
	case iOS
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

@Test(
	"Shared synchronization produces the same repository outcomes",
	arguments: [SharedHostRepositoryPlatform.macOS, .iOS]
)
@MainActor
private func sharedSynchronizationProducesTheSameRepositoryOutcomes(
	_ platform: SharedHostRepositoryPlatform
) async throws {
	let fileURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("shared-host-sync-\(UUID().uuidString).json")
	defer { try? FileManager.default.removeItem(at: fileURL) }
	let repository = makeSharedSyncRepository(for: platform, fileURL: fileURL)
	let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
	let local = SSHHost(
		id: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!,
		name: "local",
		hostname: "local.example.com",
		username: "deploy",
		credential: .agent,
		createdAt: timestamp,
		updatedAt: timestamp
	)
	try repository.createLocalHost(local)
	let client = FakeServerSyncClient()
	client.createResult = RemoteHostCreateOutput(id: "server-local")
	client.listResult = [
		RemoteHost(
			id: "server-remote",
			name: "remote",
			hostname: "remote.example.com",
			port: 22,
			username: "deploy",
			authType: "password",
			createdAt: timestamp,
			updatedAt: timestamp
		)
	]

	let operations = try await HostSynchronization.synchronize(
		repository: repository,
		client: client,
		mode: .forceFull
	)

	#expect(operations.count == 2)
	#expect(repository.hostSnapshot.count == 2)
	#expect(repository.hostSnapshot.first(where: {
		$0.id == local.id
	})?.serverId == "server-local")
	#expect(repository.hostSnapshot.first(where: {
		$0.serverId == "server-remote"
	})?.name == "remote")
}
