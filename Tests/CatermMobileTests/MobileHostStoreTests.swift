import Combine
import HostRepositoryCore
import KeychainStore
import ServerSyncClient
import SessionStore
import SSHCommandBuilder
@testable import CatermMobile
import Testing
import XCTest

private enum HostRepositoryPlatform: Sendable {
	case macOS
	case iOS
}

@MainActor
private func makeRepository(
	for platform: HostRepositoryPlatform,
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
	"Platform Host repositories persist local creation",
	arguments: [HostRepositoryPlatform.macOS, .iOS]
)
@MainActor
private func platformRepositoriesPersistLocalCreation(
	_ platform: HostRepositoryPlatform
) throws {
	let fileURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("host-repository-\(UUID().uuidString).json")
	defer { try? FileManager.default.removeItem(at: fileURL) }

	let repository = makeRepository(for: platform, fileURL: fileURL)

	let host = SSHHost(
		name: "production",
		hostname: "prod.example.com",
		username: "deploy",
		credential: .agent
	)
	try repository.createLocalHost(host)

	#expect(repository.hostSnapshot == [host])
	#expect(try HostPersistence.load(from: fileURL) == [host])
}

@Test(
	"Platform Host repositories publish local mutations",
	arguments: [HostRepositoryPlatform.macOS, .iOS]
)
@MainActor
private func platformRepositoriesPublishLocalMutations(
	_ platform: HostRepositoryPlatform
) throws {
	let fileURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("host-repository-\(UUID().uuidString).json")
	defer { try? FileManager.default.removeItem(at: fileURL) }
	let repository = makeRepository(for: platform, fileURL: fileURL)
	var mutationCount = 0
	let cancellable = repository.localMutations.sink { mutationCount += 1 }

	try repository.createLocalHost(SSHHost(
		name: "production",
		hostname: "prod.example.com",
		username: "deploy",
		credential: .agent
	))

	withExtendedLifetime(cancellable) {
		#expect(mutationCount == 1)
	}
}

@Test(
	"Platform Host repositories preserve credential state during metadata updates",
	arguments: [HostRepositoryPlatform.macOS, .iOS]
)
@MainActor
private func platformRepositoriesPreserveCredentialsDuringMetadataUpdates(
	_ platform: HostRepositoryPlatform
) throws {
	let fileURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("host-repository-\(UUID().uuidString).json")
	defer { try? FileManager.default.removeItem(at: fileURL) }
	let repository = makeRepository(for: platform, fileURL: fileURL)
	let host = SSHHost(
		name: "production",
		hostname: "prod.example.com",
		username: "deploy",
		credential: .agent,
		credentialMaterialDirty: true
	)
	try repository.createLocalHost(host)
	var edited = host
	edited.name = "production-renamed"
	edited.credential = .password
	edited.credentialMaterialDirty = false

	try repository.updateLocalHostMetadata(edited)

	let saved = try #require(repository.hostSnapshot.first)
	#expect(saved.name == "production-renamed")
	#expect(saved.credential == .agent)
	#expect(saved.credentialMaterialDirty)
	#expect(try HostPersistence.load(from: fileURL).first == saved)
}

@Test(
	"Platform Host repositories persist local deletion tombstones",
	arguments: [HostRepositoryPlatform.macOS, .iOS]
)
@MainActor
private func platformRepositoriesPersistLocalDeletionTombstones(
	_ platform: HostRepositoryPlatform
) async throws {
	let fileURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("host-repository-\(UUID().uuidString).json")
	let deletionURL = fileURL.deletingPathExtension()
		.appendingPathExtension("deletions.json")
	defer {
		try? FileManager.default.removeItem(at: fileURL)
		try? FileManager.default.removeItem(at: deletionURL)
	}
	let repository = makeRepository(for: platform, fileURL: fileURL)
	let host = SSHHost(
		serverId: "server-production",
		name: "production",
		hostname: "prod.example.com",
		username: "deploy",
		credential: .agent
	)
	try repository.createLocalHost(host)

	try await repository.deleteLocalHost(id: host.id)

	#expect(repository.hostSnapshot.isEmpty)
	#expect(try repository.pendingRemoteDeletionIDs() == ["server-production"])
	#expect(try HostPersistence.load(from: fileURL).isEmpty)
}

@Test(
	"Platform Host repositories persist remote creation without echo mutations",
	arguments: [HostRepositoryPlatform.macOS, .iOS]
)
@MainActor
private func platformRepositoriesPersistRemoteCreationWithoutEcho(
	_ platform: HostRepositoryPlatform
) throws {
	let fileURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("host-repository-\(UUID().uuidString).json")
	defer { try? FileManager.default.removeItem(at: fileURL) }
	let repository = makeRepository(for: platform, fileURL: fileURL)
	var mutationCount = 0
	let cancellable = repository.localMutations.sink { mutationCount += 1 }
	let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
	let remote = RemoteHost(
		id: "server-production",
		name: "production",
		hostname: "prod.example.com",
		port: 2222,
		username: "deploy",
		authType: "password",
		createdAt: timestamp,
		updatedAt: timestamp
	)

	let localID = try repository.createHostFromRemote(remote)

	let saved = try #require(repository.hostSnapshot.first)
	#expect(saved.id == localID)
	#expect(saved.serverId == "server-production")
	#expect(saved.credential == .password)
	#expect(try HostPersistence.load(from: fileURL) == [saved])
	withExtendedLifetime(cancellable) {
		#expect(mutationCount == 0)
	}
}

@Test(
	"Platform Host repositories apply remote conflicts without replacing credentials",
	arguments: [HostRepositoryPlatform.macOS, .iOS]
)
@MainActor
private func platformRepositoriesApplyRemoteConflictsWithoutReplacingCredentials(
	_ platform: HostRepositoryPlatform
) throws {
	let fileURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("host-repository-\(UUID().uuidString).json")
	defer { try? FileManager.default.removeItem(at: fileURL) }
	let repository = makeRepository(for: platform, fileURL: fileURL)
	let local = SSHHost(
		serverId: "server-production",
		name: "old-name",
		hostname: "old.example.com",
		username: "root",
		credential: .keyFile(keyPath: "/device/private-key", hasPassphrase: true),
		credentialMaterialDirty: true
	)
	try repository.createLocalHost(local)
	var mutationCount = 0
	let cancellable = repository.localMutations.sink { mutationCount += 1 }
	let remote = RemoteHost(
		id: "server-production",
		name: "production",
		hostname: "prod.example.com",
		port: 2222,
		username: "deploy",
		authType: "password",
		createdAt: local.createdAt,
		updatedAt: local.updatedAt.addingTimeInterval(60)
	)

	try repository.updateHostFromRemote(localID: local.id, remote: remote)

	let saved = try #require(repository.hostSnapshot.first)
	#expect(saved.name == "production")
	#expect(saved.hostname == "prod.example.com")
	#expect(saved.port == 2222)
	#expect(saved.username == "deploy")
	#expect(saved.credential == local.credential)
	#expect(saved.credentialMaterialDirty)
	withExtendedLifetime(cancellable) {
		#expect(mutationCount == 0)
	}
}

@Test(
	"Platform Host repositories persist Server IDs and dependent jump identities",
	arguments: [HostRepositoryPlatform.macOS, .iOS]
)
@MainActor
private func platformRepositoriesPersistServerAndJumpIdentities(
	_ platform: HostRepositoryPlatform
) throws {
	let fileURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("host-repository-\(UUID().uuidString).json")
	defer { try? FileManager.default.removeItem(at: fileURL) }
	let repository = makeRepository(for: platform, fileURL: fileURL)
	let jump = SSHHost(
		name: "bastion",
		hostname: "bastion.example.com",
		username: "deploy",
		credential: .agent
	)
	let child = SSHHost(
		name: "production",
		hostname: "prod.internal",
		username: "deploy",
		credential: .agent,
		jumpHostId: jump.id
	)
	try repository.createLocalHost(jump)
	try repository.createLocalHost(child)

	try repository.assignServerID("server-bastion", to: jump.id)

	let savedJump = try #require(repository.hostSnapshot.first(where: {
		$0.id == jump.id
	}))
	let savedChild = try #require(repository.hostSnapshot.first(where: {
		$0.id == child.id
	}))
	#expect(savedJump.serverId == "server-bastion")
	#expect(savedChild.jumpHostServerId == "server-bastion")
	#expect(try HostPersistence.load(from: fileURL) == repository.hostSnapshot)
}

@Test(
	"Platform Host repositories persist credential material acknowledgements",
	arguments: [HostRepositoryPlatform.macOS, .iOS]
)
@MainActor
private func platformRepositoriesPersistCredentialMaterialAcknowledgements(
	_ platform: HostRepositoryPlatform
) throws {
	let fileURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("host-repository-\(UUID().uuidString).json")
	defer { try? FileManager.default.removeItem(at: fileURL) }
	let repository = makeRepository(for: platform, fileURL: fileURL)
	let host = SSHHost(
		serverId: "server-production",
		name: "production",
		hostname: "prod.example.com",
		username: "deploy",
		credential: .password,
		credentialMaterialDirty: true
	)
	try repository.createLocalHost(host)
	var mutationCount = 0
	let cancellable = repository.localMutations.sink { mutationCount += 1 }

	try repository.markCredentialMaterialSynced(for: host.id)

	#expect(repository.hostSnapshot.first?.credentialMaterialDirty == false)
	#expect(try HostPersistence.load(from: fileURL).first?.credentialMaterialDirty == false)
	withExtendedLifetime(cancellable) {
		#expect(mutationCount == 0)
	}
}

@Test(
	"Platform Host repositories apply remote deletion without local tombstones",
	arguments: [HostRepositoryPlatform.macOS, .iOS]
)
@MainActor
private func platformRepositoriesApplyRemoteDeletionWithoutLocalTombstones(
	_ platform: HostRepositoryPlatform
) async throws {
	let fileURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("host-repository-\(UUID().uuidString).json")
	defer { try? FileManager.default.removeItem(at: fileURL) }
	let repository = makeRepository(for: platform, fileURL: fileURL)
	let host = SSHHost(
		serverId: "server-production",
		name: "production",
		hostname: "prod.example.com",
		username: "deploy",
		credential: .agent
	)
	try repository.createLocalHost(host)
	var mutationCount = 0
	let cancellable = repository.localMutations.sink { mutationCount += 1 }

	try await repository.deleteHostFromRemote(localID: host.id)

	#expect(repository.hostSnapshot.isEmpty)
	#expect(try repository.pendingRemoteDeletionIDs().isEmpty)
	#expect(try HostPersistence.load(from: fileURL).isEmpty)
	withExtendedLifetime(cancellable) {
		#expect(mutationCount == 0)
	}
}

@Test("Mobile UI upserts publish repository mutations")
@MainActor
private func mobileUIUpsertsPublishRepositoryMutations() throws {
	let fileURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("mobile-host-upsert-\(UUID().uuidString).json")
	defer { try? FileManager.default.removeItem(at: fileURL) }
	let store = MobileHostStore(fileURL: fileURL)
	var mutationCount = 0
	let cancellable = store.localMutations.sink { mutationCount += 1 }

	try store.upsert(SSHHost(
		name: "production",
		hostname: "prod.example.com",
		username: "deploy",
		credential: .agent
	))

	withExtendedLifetime(cancellable) {
		#expect(mutationCount == 1)
	}
}

@MainActor
final class MobileHostStoreTests: XCTestCase {
	private func tempURL() -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("mobile-hosts-\(UUID().uuidString).json")
	}

	private func makeHost(_ name: String) -> SSHHost {
		SSHHost(
			id: UUID(),
			name: name,
			hostname: "\(name).example.com",
			username: "deploy",
			credential: .agent
		)
	}

	func testLoadsEmptyWhenFileMissing() {
		let store = MobileHostStore(fileURL: tempURL())
		XCTAssertTrue(store.hosts.isEmpty)
	}

	func testAddPersistsAndReloadsFromSameFile() throws {
		let url = tempURL()
		let store = MobileHostStore(fileURL: url)
		let host = makeHost("prod")

		try store.add(host)

		XCTAssertEqual(store.hosts.map(\.id), [host.id])
		// A fresh store over the same file sees the persisted host: this is
		// the macOS-shared JSON format, so desktop/CloudKit stay consistent.
		let reloaded = MobileHostStore(fileURL: url)
		XCTAssertEqual(reloaded.hosts.map(\.id), [host.id])
	}

	func testUpdateReplacesHostInPlaceAndPersists() throws {
		let url = tempURL()
		let store = MobileHostStore(fileURL: url)
		var host = makeHost("prod")
		try store.add(host)

		host.name = "Renamed"
		try store.update(host)

		XCTAssertEqual(store.hosts.first?.name, "Renamed")
		XCTAssertEqual(MobileHostStore(fileURL: url).hosts.first?.name, "Renamed")
	}

	func testUpdateUnknownHostThrows() throws {
		let store = MobileHostStore(fileURL: tempURL())
		XCTAssertThrowsError(try store.update(makeHost("ghost"))) { error in
			XCTAssertEqual(error as? MobileHostStore.StoreError, .hostNotFound)
		}
	}

	func testBindingSetterPersists() throws {
		let url = tempURL()
		let store = MobileHostStore(fileURL: url)
		let host = makeHost("via-binding")

		store.binding.wrappedValue.append(host)

		XCTAssertEqual(store.hosts.map(\.id), [host.id])
		XCTAssertEqual(MobileHostStore(fileURL: url).hosts.map(\.id), [host.id])
	}

	func testDeleteRemovesAndPersists() throws {
		let url = tempURL()
		let store = MobileHostStore(fileURL: url)
		let a = makeHost("a")
		let b = makeHost("b")
		try store.add(a)
		try store.add(b)

		try store.delete(id: a.id)

		XCTAssertEqual(store.hosts.map(\.id), [b.id])
		XCTAssertEqual(MobileHostStore(fileURL: url).hosts.map(\.id), [b.id])
	}
}
