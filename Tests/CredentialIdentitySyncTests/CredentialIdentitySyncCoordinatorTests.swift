import CredentialIdentitySecurity
import CredentialIdentityStore
import CredentialIdentitySync
import CryptoKit
import Foundation
import ManagedKeyStore
import Testing

@Suite(.serialized)
@MainActor
struct CredentialIdentitySyncCoordinatorTests {
	@Test
	func encryptedPasswordRoundTripsWithoutPlaintextCloudFields() async throws {
		let cloud = InMemoryIdentitySyncClient()
		let masterKeys = TestMasterKeys()
		let sender = try Fixture(name: "sender")
		let identity = CredentialIdentity(
			name: "Production",
			username: "deploy",
			source: .password(materialID: CredentialMaterialID())
		)
		try await sender.identityStore.upsert(identity)
		try await sender.materialStore.replaceMaterial(
			for: identity,
			with: CredentialIdentityMaterial(
				password: Data("top-secret".utf8)
			)
		)

		try await sender.coordinator(
			client: cloud,
			masterKeys: masterKeys
		).sync()

		let pushed = try #require(
			await cloud.record(id: identity.id)
		)
		#expect(pushed.keyID == TestMasterKeys.keyID)
		#expect(pushed.passwordCiphertext != Data("top-secret".utf8))
		#expect(pushed.passphraseCiphertext == nil)
		#expect(pushed.privateKeyCiphertext == nil)

		let receiver = try Fixture(name: "receiver")
		try await receiver.coordinator(
			client: cloud,
			masterKeys: masterKeys
		).sync()

		let receivedIdentity = try #require(
			receiver.identityStore.identity(id: identity.id)
		)
		#expect(receivedIdentity.serverID == identity.id.uuidString)
		#expect(
			try await receiver.materialStore.snapshot(
				for: receivedIdentity
			).password == Data("top-secret".utf8)
		)
		sender.cleanup()
		receiver.cleanup()
	}

	@Test
	func certificateSyncPreservesPairingAndEncryptsOnlyPrivateHalf()
		async throws {
		let cloud = InMemoryIdentitySyncClient()
		let masterKeys = TestMasterKeys()
		let sender = try Fixture(name: "certificate-sender")
		let publicCertificate = Data(
			"ssh-ed25519-cert-v01@openssh.com AAAA".utf8
		)
		let privateKey = Data("PRIVATE KEY BYTES".utf8)
		let identity = CredentialIdentity(
			name: "Certificate",
			username: "cert-user",
			source: .sshCertificate(
				materialID: CredentialMaterialID(),
				publicCertificate: publicCertificate,
				hasPassphrase: false
			)
		)
		try await sender.identityStore.upsert(identity)
		try await sender.materialStore.replaceMaterial(
			for: identity,
			with: CredentialIdentityMaterial(privateKey: privateKey)
		)

		try await sender.coordinator(
			client: cloud,
			masterKeys: masterKeys
		).sync()

		let pushed = try #require(
			await cloud.record(id: identity.id)
		)
		guard case .sshCertificate(
			_,
			let syncedCertificate,
			_
		) = pushed.identity.source else {
			Issue.record("Expected certificate identity")
			return
		}
		#expect(syncedCertificate == publicCertificate)
		#expect(pushed.privateKeyCiphertext != privateKey)
		#expect(pushed.passwordCiphertext == nil)
		sender.cleanup()
	}

	@Test
	func secureEnclaveHandleNeverSyncsAndRemoteDeviceIsUnavailable()
		async throws {
		let cloud = InMemoryIdentitySyncClient()
		let masterKeys = TestMasterKeys()
		let sender = try Fixture(name: "enclave-sender")
		let identity = CredentialIdentity(
			name: "This Device",
			username: "admin",
			source: .secureEnclaveP256(
				materialID: CredentialMaterialID(),
				publicKey: Data([4, 5, 6]),
				originDeviceID: UUID()
			)
		)
		try await sender.identityStore.upsert(identity)
		try await sender.materialStore.replaceMaterial(
			for: identity,
			with: CredentialIdentityMaterial(
				secureEnclaveKeyBlob: Data("opaque-local-handle".utf8)
			)
		)

		try await sender.coordinator(
			client: cloud,
			masterKeys: masterKeys
		).sync()

		let pushed = try #require(
			await cloud.record(id: identity.id)
		)
		#expect(pushed.keyID == nil)
		#expect(pushed.passwordCiphertext == nil)
		#expect(pushed.passphraseCiphertext == nil)
		#expect(pushed.privateKeyCiphertext == nil)

		let receiver = try Fixture(name: "enclave-receiver")
		try await receiver.coordinator(
			client: cloud,
			masterKeys: masterKeys
		).sync()
		let received = try #require(
			receiver.identityStore.identity(id: identity.id)
		)
		#expect(
			try await receiver.materialStore.availability(for: received)
				== .unavailableOnThisDevice
		)
		sender.cleanup()
		receiver.cleanup()
	}

	@Test
	func remoteDeletionRemovesMetadataAndLocalMaterial() async throws {
		let cloud = InMemoryIdentitySyncClient()
		let masterKeys = TestMasterKeys()
		let sender = try Fixture(name: "deletion-sender")
		let identity = CredentialIdentity(
			name: "Delete Me",
			username: "root",
			source: .password(materialID: CredentialMaterialID())
		)
		try await sender.identityStore.upsert(identity)
		try await sender.materialStore.replaceMaterial(
			for: identity,
			with: CredentialIdentityMaterial(
				password: Data("secret".utf8)
			)
		)
		try await sender.coordinator(
			client: cloud,
			masterKeys: masterKeys
		).sync()

		let receiver = try Fixture(name: "deletion-receiver")
		let receiverCoordinator = receiver.coordinator(
			client: cloud,
			masterKeys: masterKeys
		)
		try await receiverCoordinator.sync()
		try await cloud.deleteCredentialIdentity(id: identity.id.uuidString)
		try await receiverCoordinator.sync()

		#expect(receiver.identityStore.identity(id: identity.id) == nil)
		let material = try await receiver.materialStore.snapshot(
			for: identity
		)
		#expect(material == CredentialIdentityMaterial())
		sender.cleanup()
		receiver.cleanup()
	}

	@Test
	func remoteDeletionWaitsUntilHostAssignmentsAreRemoved()
		async throws {
		let cloud = InMemoryIdentitySyncClient()
		let masterKeys = TestMasterKeys()
		let sender = try Fixture(name: "assigned-deletion-sender")
		let receiver = try Fixture(name: "assigned-deletion-receiver")
		let identity = CredentialIdentity(
			name: "Assigned",
			username: "deploy",
			source: .password(materialID: CredentialMaterialID())
		)
		try await sender.identityStore.upsert(identity)
		try await sender.materialStore.replaceMaterial(
			for: identity,
			with: CredentialIdentityMaterial(
				password: Data("secret".utf8)
			)
		)
		try await sender.coordinator(
			client: cloud,
			masterKeys: masterKeys
		).sync()
		let assignedHostID = UUID()
		let receiverCoordinator = receiver.coordinator(
			client: cloud,
			masterKeys: masterKeys,
			assignedHostIDs: { id in
				id == identity.id ? [assignedHostID] : []
			}
		)
		try await receiverCoordinator.sync()
		try await cloud.deleteCredentialIdentity(id: identity.id.uuidString)

		try await receiverCoordinator.sync()

		let retained = try #require(
			receiver.identityStore.identity(id: identity.id)
		)
		#expect(
			try await receiver.materialStore.snapshot(for: retained).password
				== Data("secret".utf8)
		)
		sender.cleanup()
		receiver.cleanup()
	}

	@Test
	func remoteMaterialReplacementDeletesSupersededLocalMaterial()
		async throws {
		let cloud = InMemoryIdentitySyncClient()
		let masterKeys = TestMasterKeys()
		let firstSender = try Fixture(name: "replacement-first")
		let receiver = try Fixture(name: "replacement-receiver")
		let identityID = UUID()
		let first = CredentialIdentity(
			id: identityID,
			name: "Rotating",
			username: "deploy",
			source: .password(materialID: CredentialMaterialID()),
			revision: 1
		)
		try await firstSender.identityStore.upsert(first)
		try await firstSender.materialStore.replaceMaterial(
			for: first,
			with: CredentialIdentityMaterial(
				password: Data("old-secret".utf8)
			)
		)
		try await firstSender.coordinator(
			client: cloud,
			masterKeys: masterKeys
		).sync()
		let receiverCoordinator = receiver.coordinator(
			client: cloud,
			masterKeys: masterKeys
		)
		try await receiverCoordinator.sync()

		let secondSender = try Fixture(name: "replacement-second")
		let replacement = CredentialIdentity(
			id: identityID,
			name: "Rotating",
			username: "deploy",
			source: .password(materialID: CredentialMaterialID()),
			updatedAt: Date().addingTimeInterval(10),
			revision: 2
		)
		try await secondSender.identityStore.upsert(replacement)
		try await secondSender.materialStore.replaceMaterial(
			for: replacement,
			with: CredentialIdentityMaterial(
				password: Data("new-secret".utf8)
			)
		)
		try await secondSender.coordinator(
			client: cloud,
			masterKeys: masterKeys
		).sync()
		try await receiverCoordinator.sync()

		let received = try #require(
			receiver.identityStore.identity(id: identityID)
		)
		#expect(received.source.materialID == replacement.source.materialID)
		#expect(
			try await receiver.materialStore.snapshot(for: first)
				== CredentialIdentityMaterial()
		)
		#expect(
			try await receiver.materialStore.snapshot(for: received).password
				== Data("new-secret".utf8)
		)
		firstSender.cleanup()
		secondSender.cleanup()
		receiver.cleanup()
	}

	@Test
	func staleRemoteSnapshotCannotOverwriteCleanNewerLocalMaterial()
		async throws {
		let cloud = InMemoryIdentitySyncClient()
		let masterKeys = TestMasterKeys()
		let sender = try Fixture(name: "stale-sender")
		let receiver = try Fixture(name: "stale-receiver")
		let identity = CredentialIdentity(
			name: "Production",
			username: "deploy",
			source: .password(materialID: CredentialMaterialID())
		)
		try await sender.identityStore.upsert(identity)
		try await sender.materialStore.replaceMaterial(
			for: identity,
			with: CredentialIdentityMaterial(
				password: Data("old-secret".utf8)
			)
		)
		try await sender.coordinator(
			client: cloud,
			masterKeys: masterKeys
		).sync()
		let receiverCoordinator = receiver.coordinator(
			client: cloud,
			masterKeys: masterKeys
		)
		try await receiverCoordinator.sync()

		var newer = try #require(
			receiver.identityStore.identity(id: identity.id)
		)
		newer.name = "Production Rotated"
		try await receiver.identityStore.upsert(newer)
		newer = try #require(
			receiver.identityStore.identity(id: identity.id)
		)
		try await receiver.materialStore.replaceMaterial(
			for: newer,
			with: CredentialIdentityMaterial(
				password: Data("new-secret".utf8)
			)
		)
		try await receiver.identityStore.acknowledgePush(
			id: newer.id,
			serverID: newer.serverID
		)

		try await receiverCoordinator.sync()

		let retained = try #require(
			receiver.identityStore.identity(id: identity.id)
		)
		#expect(retained.name == "Production Rotated")
		#expect(
			try await receiver.materialStore.snapshot(for: retained).password
				== Data("new-secret".utf8)
		)
		sender.cleanup()
		receiver.cleanup()
	}

	@Test
	func userEditWaitsForSyncTransactionAndWinsAfterward() async throws {
		let cloud = InMemoryIdentitySyncClient()
		let masterKeys = TestMasterKeys()
		let sender = try Fixture(name: "transaction-sender")
		let receiver = try Fixture(name: "transaction-receiver")
		let identity = CredentialIdentity(
			name: "Remote",
			username: "deploy",
			source: .password(materialID: CredentialMaterialID())
		)
		try await sender.identityStore.upsert(identity)
		try await sender.materialStore.replaceMaterial(
			for: identity,
			with: CredentialIdentityMaterial(
				password: Data("remote-secret".utf8)
			)
		)
		try await sender.coordinator(
			client: cloud,
			masterKeys: masterKeys
		).sync()

		let gatedKeys = GatedMasterKeys(base: masterKeys)
		let sync = receiver.coordinator(
			client: cloud,
			masterKeys: gatedKeys
		)
		let syncTask = Task { @MainActor in
			try await sync.sync()
		}
		await gatedKeys.waitUntilBlocked()
		let editFinished = CompletionFlag()
		let editor = CredentialIdentityEditorService(
			materialStore: receiver.materialStore
		)
		let editTask = Task { @MainActor in
			_ = try await editor.save(
				CredentialIdentityEditorInput(
					existingIdentity: identity,
					kind: .password,
					name: "Local Edit",
					username: "deploy",
					password: Data("local-secret".utf8),
					originDeviceID: UUID(),
					localizedReason: "Test"
				),
				to: receiver.identityStore
			)
			await editFinished.markFinished()
		}
		for _ in 0..<20 {
			await Task.yield()
		}
		#expect(await !editFinished.isFinished)

		await gatedKeys.release()
		try await syncTask.value
		try await editTask.value

		let edited = try #require(
			receiver.identityStore.identity(id: identity.id)
		)
		#expect(edited.name == "Local Edit")
		#expect(
			try await receiver.materialStore.snapshot(for: edited).password
				== Data("local-secret".utf8)
		)
		sender.cleanup()
		receiver.cleanup()
	}
}

@MainActor
private struct Fixture {
	let rootURL: URL
	let identityStore: CredentialIdentityStore
	let materialStore: CredentialIdentityMaterialStore

	init(name: String) throws {
		rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
			"identity-sync-\(name)-\(UUID().uuidString)",
			isDirectory: true
		)
		identityStore = CredentialIdentityStore(
			fileURL: rootURL.appendingPathComponent("identities.json")
		)
		materialStore = CredentialIdentityMaterialStore(
			secrets: InMemoryIdentitySecretStore(),
			managedKeys: ManagedKeyStore(
				rootURL: rootURL.appendingPathComponent(
					"keys",
					isDirectory: true
				)
			),
			secureEnclave: UnavailableSecureEnclaveProvider()
		)
	}

	func coordinator(
		client: InMemoryIdentitySyncClient,
		masterKeys: any IdentitySyncMasterKeyProviding,
		assignedHostIDs:
			@escaping @MainActor (UUID) -> Set<UUID> = { _ in [] }
	) -> CredentialIdentitySyncCoordinator {
		CredentialIdentitySyncCoordinator(
			store: identityStore,
			materialStore: materialStore,
			client: client,
			masterKeys: masterKeys,
			assignedHostIDs: assignedHostIDs
		)
	}

	func cleanup() {
		try? FileManager.default.removeItem(at: rootURL)
	}
}

private actor CompletionFlag {
	private(set) var isFinished = false

	func markFinished() {
		isFinished = true
	}
}

private actor GatedMasterKeys: IdentitySyncMasterKeyProviding {
	private let base: TestMasterKeys
	private var isBlocked = false
	private var waiters: [CheckedContinuation<Void, Never>] = []
	private var releaseContinuation: CheckedContinuation<Void, Never>?

	init(base: TestMasterKeys) {
		self.base = base
	}

	func identitySyncKey() async throws -> (
		keyID: String,
		key: SymmetricKey
	)? {
		try await base.identitySyncKey()
	}

	func identitySyncKey(keyID: String) async throws -> SymmetricKey? {
		isBlocked = true
		waiters.forEach { $0.resume() }
		waiters.removeAll()
		await withCheckedContinuation {
			releaseContinuation = $0
		}
		return try await base.identitySyncKey(keyID: keyID)
	}

	func waitUntilBlocked() async {
		guard !isBlocked else { return }
		await withCheckedContinuation { waiters.append($0) }
	}

	func release() {
		releaseContinuation?.resume()
		releaseContinuation = nil
	}
}

private actor InMemoryIdentitySyncClient: CredentialIdentitySyncClient {
	private var records: [UUID: CredentialIdentitySyncRecord] = [:]

	func listCredentialIdentities() async throws
		-> [CredentialIdentitySyncRecord] {
		Array(records.values)
	}

	func upsertCredentialIdentity(
		_ record: CredentialIdentitySyncRecord
	) async throws -> String {
		var stored = record
		stored.identity.serverID = record.identity.id.uuidString
		records[record.identity.id] = stored
		return record.identity.id.uuidString
	}

	func deleteCredentialIdentity(id: String) async throws {
		guard let identityID = UUID(uuidString: id) else { return }
		records[identityID] = nil
	}

	func record(id: UUID) -> CredentialIdentitySyncRecord? {
		records[id]
	}
}

private struct TestMasterKeys: IdentitySyncMasterKeyProviding {
	static let keyID = "test-master-key"
	private let key = SymmetricKey(
		data: Data(repeating: 0x42, count: 32)
	)

	func identitySyncKey() async throws -> (
		keyID: String,
		key: SymmetricKey
	)? {
		(Self.keyID, key)
	}

	func identitySyncKey(keyID: String) async throws -> SymmetricKey? {
		keyID == Self.keyID ? key : nil
	}
}

private final class InMemoryIdentitySecretStore: IdentitySecretStoring,
	@unchecked Sendable {
	private let lock = NSLock()
	private var values: [String: Data] = [:]

	func read(account: String) throws -> Data? {
		lock.withLock { values[account] }
	}

	func write(_ data: Data, account: String) throws {
		lock.withLock { values[account] = data }
	}

	func delete(account: String) throws {
		lock.withLock { values[account] = nil }
	}
}

private struct UnavailableSecureEnclaveProvider:
	SecureEnclaveIdentityKeyProviding {
	let isAvailable = false

	func create(localizedReason: String) throws -> SecureEnclaveIdentityKey {
		throw SecureEnclaveIdentityError.unavailable
	}

	func restore(
		dataRepresentation: Data,
		localizedReason: String
	) throws -> SecureEnclaveIdentityKey {
		throw SecureEnclaveIdentityError.unavailable
	}
}
