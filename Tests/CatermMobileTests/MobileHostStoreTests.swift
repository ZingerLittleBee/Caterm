import Combine
import HostRepositoryCore
import KeychainStore
import ServerSyncClient
import SessionStore
import SSHCommandBuilder
@testable import CatermMobile
import Testing
import XCTest

private final class RecordingCredentialStore: MobileCredentialStoring, @unchecked Sendable {
	enum Failure: Error {
		case rejected
	}

	var values: [String: String] = [:]
	var failingDeleteAccounts: Set<String> = []

	func set(account: String, secret: String) throws {
		values[account] = secret
	}

	func get(account: String, interaction _: KeychainReadInteraction) throws -> String {
		guard let value = values[account] else { throw KeychainError.notFound }
		return value
	}

	func delete(account: String) throws {
		guard !failingDeleteAccounts.contains(account) else { throw Failure.rejected }
		guard values.removeValue(forKey: account) != nil else {
			throw KeychainError.notFound
		}
	}
}

private actor PersistenceMutationGate {
	private var blockedContinuation: CheckedContinuation<Void, Never>?
	private var releaseContinuation: CheckedContinuation<Void, Never>?
	private var isReleased = false

	func block() async {
		guard !isReleased else { return }
		await withCheckedContinuation { continuation in
			blockedContinuation = continuation
		}
		guard !isReleased else { return }
		await withCheckedContinuation { continuation in
			releaseContinuation = continuation
		}
	}

	func waitUntilBlocked() async {
		while blockedContinuation == nil {
			await Task.yield()
		}
		blockedContinuation?.resume()
		blockedContinuation = nil
	}

	func release() {
		isReleased = true
		releaseContinuation?.resume()
		releaseContinuation = nil
	}
}

private enum HostRepositoryPlatform: Sendable {
	case macOS
	case iOS
}

private final class DeletionDrainClient: IncrementalHostSyncClient, @unchecked Sendable {
	private(set) var deletedHostIDs: [String] = []

	func listHosts() async throws -> [RemoteHost] { [] }
	func createHost(_: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput {
		RemoteHostCreateOutput(id: "unused")
	}
	func updateHost(_: RemoteHostUpdateInput) async throws {}
	func deleteHost(id: String) async throws { deletedHostIDs.append(id) }
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
			changedHosts: [],
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
	"Platform Host repositories persist and drain compensation deletions",
	arguments: [HostRepositoryPlatform.macOS, .iOS]
)
@MainActor
private func platformRepositoriesPersistAndDrainCompensationDeletions(
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

	var repository = makeRepository(for: platform, fileURL: fileURL)
	try await repository.recordPendingRemoteDeletion(serverID: "server-orphan")
	repository = makeRepository(for: platform, fileURL: fileURL)
	let pendingBeforeDrain = try await repository.pendingRemoteDeletionIDs()
	#expect(pendingBeforeDrain == ["server-orphan"])

	let client = DeletionDrainClient()
	_ = try await HostSynchronization.synchronize(
		repository: repository,
		client: client,
		mode: .forceFull
	)
	#expect(client.deletedHostIDs == ["server-orphan"])

	repository = makeRepository(for: platform, fileURL: fileURL)
	#expect(try await repository.pendingRemoteDeletionIDs().isEmpty)
}

@Test(
	"Platform Host repositories persist local creation",
	arguments: [HostRepositoryPlatform.macOS, .iOS]
)
@MainActor
private func platformRepositoriesPersistLocalCreation(
	_ platform: HostRepositoryPlatform
) async throws {
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
	try await repository.createLocalHost(host)

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
) async throws {
	let fileURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("host-repository-\(UUID().uuidString).json")
	defer { try? FileManager.default.removeItem(at: fileURL) }
	let repository = makeRepository(for: platform, fileURL: fileURL)
	var mutationCount = 0
	let cancellable = repository.localMutations.sink { mutationCount += 1 }

	try await repository.createLocalHost(SSHHost(
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
) async throws {
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
	try await repository.createLocalHost(host)
	var edited = host
	edited.name = "production-renamed"
	edited.credential = .password
	edited.credentialMaterialDirty = false

	try await repository.updateLocalHostMetadata(edited)

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
	try await repository.createLocalHost(host)

	try await repository.deleteLocalHost(id: host.id)

	#expect(repository.hostSnapshot.isEmpty)
	#expect(try await repository.pendingRemoteDeletionIDs() == ["server-production"])
	#expect(try HostPersistence.load(from: fileURL).isEmpty)
}

@Test(
	"Platform Host repositories persist remote creation without echo mutations",
	arguments: [HostRepositoryPlatform.macOS, .iOS]
)
@MainActor
private func platformRepositoriesPersistRemoteCreationWithoutEcho(
	_ platform: HostRepositoryPlatform
) async throws {
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

	let localID = try await repository.createHostFromRemote(remote)

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
) async throws {
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
	try await repository.createLocalHost(local)
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

	try await repository.updateHostFromRemote(localID: local.id, remote: remote)

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
) async throws {
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
	try await repository.createLocalHost(jump)
	try await repository.createLocalHost(child)

	try await repository.assignServerID("server-bastion", to: jump.id)

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
		credential: .password,
		credentialMaterialDirty: true
	)
	try await repository.createLocalHost(host)
	var mutationCount = 0
	let cancellable = repository.localMutations.sink { mutationCount += 1 }

	try await repository.markCredentialMaterialSynced(for: host.id)

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
	try await repository.createLocalHost(host)
	var mutationCount = 0
	let cancellable = repository.localMutations.sink { mutationCount += 1 }

	try await repository.deleteHostFromRemote(localID: host.id)

	#expect(repository.hostSnapshot.isEmpty)
	#expect(try await repository.pendingRemoteDeletionIDs().isEmpty)
	#expect(try HostPersistence.load(from: fileURL).isEmpty)
	withExtendedLifetime(cancellable) {
		#expect(mutationCount == 0)
	}
}

@Test("Mobile UI upserts publish repository mutations")
@MainActor
private func mobileUIUpsertsPublishRepositoryMutations() async throws {
	let fileURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("mobile-host-upsert-\(UUID().uuidString).json")
	defer { try? FileManager.default.removeItem(at: fileURL) }
	let store = MobileHostStore(fileURL: fileURL)
	var mutationCount = 0
	let cancellable = store.localMutations.sink { mutationCount += 1 }

	try await store.upsert(SSHHost(
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

	func testAddPersistsAndReloadsFromSameFile() async throws {
		let url = tempURL()
		let store = MobileHostStore(fileURL: url)
		let host = makeHost("prod")

		try await store.add(host)

		XCTAssertEqual(store.hosts.map(\.id), [host.id])
		// A fresh store over the same file sees the persisted host: this is
		// the macOS-shared JSON format, so desktop/CloudKit stay consistent.
		let reloaded = MobileHostStore(fileURL: url)
		XCTAssertEqual(reloaded.hosts.map(\.id), [host.id])
	}

	func testUpdateReplacesHostInPlaceAndPersists() async throws {
		let url = tempURL()
		let store = MobileHostStore(fileURL: url)
		var host = makeHost("prod")
		try await store.add(host)

		host.name = "Renamed"
		try await store.update(host)

		XCTAssertEqual(store.hosts.first?.name, "Renamed")
		XCTAssertEqual(MobileHostStore(fileURL: url).hosts.first?.name, "Renamed")
	}

	func testUpdateUnknownHostThrows() async throws {
		let store = MobileHostStore(fileURL: tempURL())
		do {
			try await store.update(makeHost("ghost"))
			XCTFail("Expected an unknown Host error")
		} catch {
			XCTAssertEqual(error as? MobileHostStore.StoreError, .hostNotFound)
		}
	}

	func testBindingSetterPersists() async throws {
		let url = tempURL()
		let store = MobileHostStore(fileURL: url)
		let host = makeHost("via-binding")

		store.binding.wrappedValue.append(host)
		await waitUntil { store.hosts.map(\.id) == [host.id] }

		XCTAssertEqual(store.hosts.map(\.id), [host.id])
		XCTAssertEqual(MobileHostStore(fileURL: url).hosts.map(\.id), [host.id])
	}

	func testBindingPersistenceFailureIsPublishedWithoutMutatingHosts() async throws {
		let directoryURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("mobile-hosts-directory-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directoryURL,
			withIntermediateDirectories: true
		)
		defer { try? FileManager.default.removeItem(at: directoryURL) }
		let store = MobileHostStore(fileURL: directoryURL)
		let host = makeHost("cannot-persist")

		store.binding.wrappedValue = [host]
		await waitUntil { store.lastPersistenceFailure != nil }

		XCTAssertTrue(store.hosts.isEmpty)
		XCTAssertNotNil(store.lastPersistenceFailure)
	}

	func testDeleteRemovesAndPersists() async throws {
		let url = tempURL()
		let store = MobileHostStore(fileURL: url)
		let a = makeHost("a")
		let b = makeHost("b")
		try await store.add(a)
		try await store.add(b)

		try await store.delete(id: a.id)

		XCTAssertEqual(store.hosts.map(\.id), [b.id])
		XCTAssertEqual(MobileHostStore(fileURL: url).hosts.map(\.id), [b.id])
	}

	func testAccountResetRejectsAHostSaveAlreadyWaitingToPersist() async throws {
		let url = tempURL()
		let accountAHost = makeHost("account-a")
		try HostPersistence.save([accountAHost], to: url)
		let gate = PersistenceMutationGate()
		let persistence = MobileHostPersistence(
			hostsURL: url,
			hosts: [accountAHost],
			beforeMutation: { await gate.block() }
		)
		let store = MobileHostStore(fileURL: url, persistence: persistence)
		let staleSave = Task { @MainActor in
			do {
				try await store.upsert(self.makeHost("stale-account-a"))
				return false
			} catch {
				return error as? MobileHostStore.StoreError
					== .accountTransitionInProgress
			}
		}

		await gate.waitUntilBlocked()
		try await store.resetForAccountChange()
		try store.finishAccountTransition()
		await gate.release()
		let staleSaveWasRejected = await staleSave.value

		XCTAssertTrue(staleSaveWasRejected)
		XCTAssertTrue(store.hosts.isEmpty)
		XCTAssertTrue(try HostPersistence.load(from: url).isEmpty)
	}

	func testIdentityBoundStateIncludesHostsAndDeletionOutbox() async throws {
		let url = tempURL()
		let store = MobileHostStore(fileURL: url)

		var hasState = await store.hasIdentityBoundState()
		XCTAssertFalse(hasState)
		try await store.add(makeHost("local-account-state"))
		hasState = await store.hasIdentityBoundState()
		XCTAssertTrue(hasState)

		try await store.resetForAccountChange()
		try store.finishAccountTransition()
		hasState = await store.hasIdentityBoundState()
		XCTAssertFalse(hasState)
		try await store.recordPendingRemoteDeletion(serverID: "stale-server-id")
		hasState = await store.hasIdentityBoundState()
		XCTAssertTrue(hasState)
	}

	func testIdentityBoundStateFailsClosedForUnreadableDeletionOutbox() async throws {
		let url = tempURL()
		let outboxURL = url.deletingPathExtension()
			.appendingPathExtension("deletions.json")
		try Data("not-json".utf8).write(to: outboxURL)
		defer { try? FileManager.default.removeItem(at: outboxURL) }
		let store = MobileHostStore(fileURL: url)

		let hasState = await store.hasIdentityBoundState()

		XCTAssertTrue(hasState)
	}

	func testLocalDeleteClearsCredentialsAndPersistsTombstone() async throws {
		let url = tempURL()
		let storage = RecordingCredentialStore()
		let writer = MobileCredentialWriter(storage: storage)
		let store = MobileHostStore(
			fileURL: url,
			credentialWriter: writer
		)
		let host = SSHHost(
			serverId: "server-prod",
			name: "prod",
			hostname: "prod.example.com",
			username: "deploy",
			credential: .password
		)
		storage.values[MobileCredentialPlan.passwordAccount(host.id)] = "secret"
		try await store.add(host)

		try await store.deleteLocalHost(id: host.id)

		XCTAssertTrue(storage.values.isEmpty)
		XCTAssertTrue(store.hosts.isEmpty)
		let pending = try await store.pendingRemoteDeletionIDs()
		XCTAssertEqual(pending, ["server-prod"])
	}

	func testRemoteDeleteClearsCredentialsWithoutCreatingTombstone() async throws {
		let url = tempURL()
		let storage = RecordingCredentialStore()
		let writer = MobileCredentialWriter(storage: storage)
		let store = MobileHostStore(
			fileURL: url,
			credentialWriter: writer
		)
		let host = SSHHost(
			serverId: "server-prod",
			name: "prod",
			hostname: "prod.example.com",
			username: "deploy",
			credential: .password
		)
		storage.values[MobileCredentialPlan.passwordAccount(host.id)] = "secret"
		try await store.add(host)

		try await store.deleteHostFromRemote(localID: host.id)

		XCTAssertTrue(storage.values.isEmpty)
		XCTAssertTrue(store.hosts.isEmpty)
		let pending = try await store.pendingRemoteDeletionIDs()
		XCTAssertTrue(pending.isEmpty)
	}

	func testCredentialCleanupFailureLeavesHostAndTombstoneUnchanged() async throws {
		let url = tempURL()
		let storage = RecordingCredentialStore()
		let writer = MobileCredentialWriter(storage: storage)
		let store = MobileHostStore(
			fileURL: url,
			credentialWriter: writer
		)
		let host = SSHHost(
			serverId: "server-prod",
			name: "prod",
			hostname: "prod.example.com",
			username: "deploy",
			credential: .password
		)
		let passwordAccount = MobileCredentialPlan.passwordAccount(host.id)
		storage.values[passwordAccount] = "secret"
		storage.failingDeleteAccounts = [passwordAccount]
		try await store.add(host)

		do {
			try await store.deleteLocalHost(id: host.id)
			XCTFail("Expected credential cleanup to fail")
		} catch RecordingCredentialStore.Failure.rejected {
			// Expected.
		}

		XCTAssertEqual(store.hosts.map(\.id), [host.id])
		let pending = try await store.pendingRemoteDeletionIDs()
		XCTAssertTrue(pending.isEmpty)
		XCTAssertEqual(try HostPersistence.load(from: url).map(\.id), [host.id])
		XCTAssertEqual(storage.values[passwordAccount], "secret")
	}

	private func waitUntil(
		_ predicate: @MainActor () -> Bool
	) async {
		for _ in 0..<100 where !predicate() {
			await Task.yield()
		}
	}
}
