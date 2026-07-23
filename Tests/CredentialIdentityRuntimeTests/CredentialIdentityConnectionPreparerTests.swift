import CredentialIdentitySecurity
import CredentialIdentityStore
import Foundation
import ManagedKeyStore
import SSHCommandBuilder
import Testing
@testable import CredentialIdentityRuntime

@Suite(.serialized)
struct CredentialIdentityConnectionPreparerTests {
	@Test
	func preparesPasswordWithoutCopyingHostSecret() async throws {
		let fixture = try RuntimePreparationFixture()
		let materialID = CredentialMaterialID()
		let identity = CredentialIdentity(
			name: "Shared ops",
			username: "ops",
			source: .password(materialID: materialID)
		)
		try await fixture.materialStore.replaceMaterial(
			for: identity,
			with: .init(password: Data("secret".utf8))
		)
		let prepared = try await fixture.preparer.prepare(
			host: fixture.host(assignedTo: identity.id),
			identity: identity
		)

		#expect(prepared.host.username == "ops")
		#expect(prepared.host.credential == .password)
		#expect(
			prepared.credentialLookup?.passwordAccount
				== CredentialIdentityKeychainContract.account(
					materialID: materialID,
					kind: .password
				)
		)
		#expect(
			prepared.credentialLookup?
				.useDataProtectionKeychain == true
		)
	}

	@Test
	func preparesManagedKeyAtStableMaterialPath() async throws {
		let fixture = try RuntimePreparationFixture()
		let materialID = CredentialMaterialID()
		let identity = CredentialIdentity(
			name: "Deploy",
			username: "deploy",
			source: .managedKey(
				materialID: materialID,
				hasPassphrase: true
			)
		)
		try await fixture.materialStore.replaceMaterial(
			for: identity,
			with: .init(
				passphrase: Data("phrase".utf8),
				privateKey: Data("private-key".utf8)
			)
		)
		let prepared = try await fixture.preparer.prepare(
			host: fixture.host(assignedTo: identity.id),
			identity: identity
		)

		#expect(
			prepared.host.credential == .keyFile(
				keyPath: fixture.managedKeys.path(
					materialID: materialID.rawValue
				).path,
				hasPassphrase: true
			)
		)
		#expect(
			prepared.credentialLookup?.passphraseAccount
				== CredentialIdentityKeychainContract.account(
					materialID: materialID,
					kind: .passphrase
				)
		)
	}

	@Test
	func preparesAndCleansCertificateFile() async throws {
		let fixture = try RuntimePreparationFixture()
		let materialID = CredentialMaterialID()
		let certificate = Data(
			"ssh-rsa-cert-v01@openssh.com AAAA test".utf8
		)
		let identity = CredentialIdentity(
			name: "Certificate",
			username: "cert-user",
			source: .sshCertificate(
				materialID: materialID,
				publicCertificate: certificate,
				hasPassphrase: false
			)
		)
		try await fixture.materialStore.replaceMaterial(
			for: identity,
			with: .init(privateKey: Data("private-key".utf8))
		)
		let prepared = try await fixture.preparer.prepare(
			host: fixture.host(assignedTo: identity.id),
			identity: identity
		)
		let certificatePath = try #require(
			prepared.runtimeIdentity?.certificatePath
		)
		let attributes = try FileManager.default.attributesOfItem(
			atPath: certificatePath
		)
		let permissions = try #require(
			attributes[.posixPermissions] as? NSNumber
		)

		#expect(
			try Data(contentsOf: URL(
				fileURLWithPath: certificatePath
			)) == certificate
		)
		#expect(
			permissions.intValue & 0o777 == 0o600
		)

		prepared.stop()

		#expect(
			!FileManager.default.fileExists(
				atPath: certificatePath
			)
		)
	}

	@Test
	func missingIdentityFailsWithoutLegacyFallback() async throws {
		let fixture = try RuntimePreparationFixture()
		let identityID = UUID()

		await #expect(
			throws:
				CredentialIdentityPreparationError
					.missingIdentity(identityID)
		) {
			try await fixture.preparer.prepare(
				host: fixture.host(assignedTo: identityID),
				identity: nil
			)
		}
	}
}

private struct RuntimePreparationFixture {
	let root: URL
	let secrets = RuntimeMemoryIdentitySecrets()
	let managedKeys: ManagedKeyStore
	let materialStore: CredentialIdentityMaterialStore
	let preparer: CredentialIdentityConnectionPreparer

	init() throws {
		root = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		managedKeys = ManagedKeyStore(rootURL: root)
		materialStore = CredentialIdentityMaterialStore(
			secrets: secrets,
			managedKeys: managedKeys,
			secureEnclave: RuntimeUnavailableSecureEnclave()
		)
		preparer = CredentialIdentityConnectionPreparer(
			materialStore: materialStore,
			managedKeyStore: managedKeys
		)
	}

	func host(assignedTo identityID: UUID) -> SSHHost {
		var host = SSHHost(
			name: "Server",
			hostname: "server.example.com",
			port: 22,
			username: "legacy",
			credential: .password
		)
		host.credentialIdentity = .init(
			identityID: identityID,
			migrationState: .confirmed
		)
		return host
	}
}

private final class RuntimeMemoryIdentitySecrets:
	IdentitySecretStoring, @unchecked Sendable {
	private let lock = NSLock()
	private var values: [String: Data] = [:]

	func read(account: String) throws -> Data? {
		lock.withLock { values[account] }
	}

	func write(_ data: Data, account: String) throws {
		lock.withLock { values[account] = data }
	}

	func delete(account: String) throws {
		_ = lock.withLock { values.removeValue(forKey: account) }
	}
}

private struct RuntimeUnavailableSecureEnclave:
	SecureEnclaveIdentityKeyProviding {
	var isAvailable: Bool { false }

	func create(localizedReason: String) throws
		-> SecureEnclaveIdentityKey {
		throw SecureEnclaveIdentityError.unavailable
	}

	func restore(
		dataRepresentation: Data,
		localizedReason: String
	) throws -> SecureEnclaveIdentityKey {
		throw SecureEnclaveIdentityError.unavailable
	}
}
