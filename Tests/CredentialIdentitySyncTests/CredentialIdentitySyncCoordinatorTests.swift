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
		try sender.identityStore.upsert(identity)
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
		try sender.identityStore.upsert(identity)
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
		try sender.identityStore.upsert(identity)
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
		try sender.identityStore.upsert(identity)
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
		masterKeys: TestMasterKeys
	) -> CredentialIdentitySyncCoordinator {
		CredentialIdentitySyncCoordinator(
			store: identityStore,
			materialStore: materialStore,
			client: client,
			masterKeys: masterKeys
		)
	}

	func cleanup() {
		try? FileManager.default.removeItem(at: rootURL)
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
