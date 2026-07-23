import CredentialIdentitySecurity
import CredentialIdentityStore
import Foundation
import ManagedKeyStore
import Testing

@Suite(.serialized)
struct CredentialIdentityMaterialStoreTests {
	@Test
	func storesSharedPasswordUnderStableMaterialReference() async throws {
		let fixture = try Fixture()
		defer { fixture.cleanup() }
		let identity = CredentialIdentity(
			name: "Shared",
			username: "ops",
			source: .password(materialID: CredentialMaterialID())
		)

		try await fixture.store.replaceMaterial(
			for: identity,
			with: CredentialIdentityMaterial(
				password: Data("secret".utf8)
			)
		)

		#expect(
			try await fixture.store.snapshot(for: identity).password
				== Data("secret".utf8)
		)
		#expect(
			try await fixture.store.availability(for: identity) == .available
		)
	}

	@Test
	func keepsCertificateAndPrivateKeyPairByMaterialReference() async throws {
		let fixture = try Fixture()
		defer { fixture.cleanup() }
		let identity = CredentialIdentity(
			name: "Certified",
			username: "deploy",
			source: .sshCertificate(
				materialID: CredentialMaterialID(),
				publicCertificate: Data("ssh-ed25519-cert-v01".utf8),
				hasPassphrase: true
			)
		)
		let material = CredentialIdentityMaterial(
			passphrase: Data("phrase".utf8),
			privateKey: Data("private-key".utf8)
		)

		try await fixture.store.replaceMaterial(
			for: identity,
			with: material
		)

		#expect(try await fixture.store.snapshot(for: identity) == material)
	}

	@Test
	func deviceBoundIdentityIsUnavailableWithoutLocalKeyBlob() async throws {
		let fixture = try Fixture()
		defer { fixture.cleanup() }
		let identity = CredentialIdentity(
			name: "This Mac",
			username: "admin",
			source: .secureEnclaveP256(
				materialID: CredentialMaterialID(),
				publicKey: Data([1, 2, 3]),
				originDeviceID: UUID()
			)
		)

		#expect(
			try await fixture.store.availability(for: identity)
				== .unavailableOnThisDevice
		)
	}

	@Test
	func invalidReplacementLeavesPreviousMaterialIntact() async throws {
		let fixture = try Fixture()
		defer { fixture.cleanup() }
		let identity = CredentialIdentity(
			name: "Password",
			username: "root",
			source: .password(materialID: CredentialMaterialID())
		)
		let original = CredentialIdentityMaterial(
			password: Data("original".utf8)
		)
		try await fixture.store.replaceMaterial(
			for: identity,
			with: original
		)

		await #expect(throws:
			CredentialIdentityMaterialStoreError.invalidMaterialForSource
		) {
			try await fixture.store.replaceMaterial(
				for: identity,
				with: CredentialIdentityMaterial(
					password: Data("replacement".utf8),
					privateKey: Data("unexpected".utf8)
				)
			)
		}
		#expect(try await fixture.store.snapshot(for: identity) == original)
	}

	@Test
	func deletionRemovesEverySecretAndManagedKey() async throws {
		let fixture = try Fixture()
		defer { fixture.cleanup() }
		let identity = CredentialIdentity(
			name: "Key",
			username: "root",
			source: .managedKey(
				materialID: CredentialMaterialID(),
				hasPassphrase: false
			)
		)
		try await fixture.store.replaceMaterial(
			for: identity,
			with: CredentialIdentityMaterial(
				privateKey: Data("private".utf8)
			)
		)

		try await fixture.store.delete(identity: identity)

		#expect(
			try await fixture.store.availability(for: identity) == .incomplete
		)
		#expect(try await fixture.store.snapshot(for: identity)
			== CredentialIdentityMaterial())
	}
}

private struct Fixture {
	let rootURL: URL
	let store: CredentialIdentityMaterialStore

	init() throws {
		rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
			"identity-material-\(UUID().uuidString)",
			isDirectory: true
		)
		store = CredentialIdentityMaterialStore(
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

	func cleanup() {
		try? FileManager.default.removeItem(at: rootURL)
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
