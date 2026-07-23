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
	func preparesPasswordAsConnectionScopedSnapshot() async throws {
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
		let passwordAccount = try #require(
			prepared.credentialLookup?.passwordAccount
		)
		#expect(passwordAccount.hasPrefix("runtime."))
		#expect(
			try fixture.secrets.read(account: passwordAccount)
				== Data("secret".utf8)
		)
		try await fixture.materialStore.replaceMaterial(
			for: identity,
			with: .init(password: Data("rotated".utf8))
		)
		#expect(
			try fixture.secrets.read(account: passwordAccount)
				== Data("secret".utf8)
		)
		#expect(
			prepared.credentialLookup?
				.useDataProtectionKeychain == true
		)
	}

	@Test
	func preparesManagedKeyAsConnectionScopedSnapshot() async throws {
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

		guard case .keyFile(let keyPath, let hasPassphrase) =
			prepared.host.credential else {
			Issue.record("Expected an isolated private-key file")
			return
		}
		#expect(hasPassphrase)
		#expect(
			keyPath != fixture.managedKeys.path(
				materialID: materialID.rawValue
			).path
		)
		#expect(
			try Data(contentsOf: URL(fileURLWithPath: keyPath))
				== Data("private-key".utf8)
		)
		let passphraseAccount = try #require(
			prepared.credentialLookup?.passphraseAccount
		)
		#expect(passphraseAccount.hasPrefix("runtime."))
		#expect(
			try fixture.secrets.read(account: passphraseAccount)
				== Data("phrase".utf8)
		)
		try await fixture.materialStore.replaceMaterial(
			for: identity,
			with: .init(
				passphrase: Data("rotated-phrase".utf8),
				privateKey: Data("rotated-key".utf8)
			)
		)
		#expect(
			try Data(contentsOf: URL(fileURLWithPath: keyPath))
				== Data("private-key".utf8)
		)
		#expect(
			try fixture.secrets.read(account: passphraseAccount)
				== Data("phrase".utf8)
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

	@Test
	func scavengesCrashedRuntimeWithoutTouchingActiveConnection()
		async throws {
		let fixture = try RuntimePreparationFixture()
		var activePreparer: CredentialIdentityConnectionPreparer? =
			CredentialIdentityConnectionPreparer(
				materialStore: fixture.materialStore,
				managedKeyStore: fixture.managedKeys,
				runtimeSecrets: fixture.secrets,
				runtimeRootURL: fixture.runtimeRoot
			)
		let activeID = CredentialMaterialID()
		let activeIdentity = CredentialIdentity(
			name: "Active",
			username: "deploy",
			source: .managedKey(
				materialID: activeID,
				hasPassphrase: true
			)
		)
		try await fixture.materialStore.replaceMaterial(
			for: activeIdentity,
			with: .init(
				passphrase: Data("active-passphrase".utf8),
				privateKey: Data("active-key".utf8)
			)
		)
		let active = try await activePreparer?.prepare(
			host: fixture.host(assignedTo: activeIdentity.id),
			identity: activeIdentity
		)
		let activeConnection = try #require(active)
		activePreparer = nil
		guard case .keyFile(let activeKeyPath, _) =
			activeConnection.host.credential else {
			Issue.record("Expected an active runtime key")
			return
		}
		let activeAccount = try #require(
			activeConnection.credentialLookup?.passphraseAccount
		)

		let staleIdentifier = UUID().uuidString.lowercased()
		let staleDirectory = fixture.runtimeRoot.appendingPathComponent(
			"caterm-identity-runtime-999999-\(staleIdentifier)",
			isDirectory: true
		)
		try FileManager.default.createDirectory(
			at: staleDirectory,
			withIntermediateDirectories: true
		)
		try Data("orphan-key".utf8).write(
			to: staleDirectory.appendingPathComponent("orphan")
		)
		let staleAccount = "runtime.\(staleIdentifier).orphan.password"
		try fixture.secrets.write(
			Data("orphan-secret".utf8),
			account: staleAccount
		)
		let secondPreparer = CredentialIdentityConnectionPreparer(
			materialStore: fixture.materialStore,
			managedKeyStore: fixture.managedKeys,
			runtimeSecrets: fixture.secrets,
			runtimeRootURL: fixture.runtimeRoot
		)
		let secondID = CredentialMaterialID()
		let secondIdentity = CredentialIdentity(
			name: "Second",
			username: "deploy",
			source: .password(materialID: secondID)
		)
		try await fixture.materialStore.replaceMaterial(
			for: secondIdentity,
			with: .init(password: Data("second".utf8))
		)
		let second = try await secondPreparer.prepare(
			host: fixture.host(assignedTo: secondIdentity.id),
			identity: secondIdentity
		)

		#expect(!FileManager.default.fileExists(atPath: staleDirectory.path))
		#expect(try fixture.secrets.read(account: staleAccount) == nil)
		#expect(FileManager.default.fileExists(atPath: activeKeyPath))
		#expect(
			try fixture.secrets.read(account: activeAccount)
				== Data("active-passphrase".utf8)
		)
		activeConnection.stop()
		second.stop()
	}
}

private struct RuntimePreparationFixture {
	let root: URL
	let runtimeRoot: URL
	let secrets = RuntimeMemoryIdentitySecrets()
	let managedKeys: ManagedKeyStore
	let materialStore: CredentialIdentityMaterialStore
	let preparer: CredentialIdentityConnectionPreparer

	init() throws {
		root = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		runtimeRoot = root.appendingPathComponent(
			"runtime",
			isDirectory: true
		)
		managedKeys = ManagedKeyStore(rootURL: root)
		materialStore = CredentialIdentityMaterialStore(
			secrets: secrets,
			managedKeys: managedKeys,
			secureEnclave: RuntimeUnavailableSecureEnclave()
		)
		preparer = CredentialIdentityConnectionPreparer(
			materialStore: materialStore,
			managedKeyStore: managedKeys,
			runtimeSecrets: secrets,
			runtimeRootURL: runtimeRoot
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
	IdentitySecretStoring, IdentityRuntimeSecretScavenging,
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
		_ = lock.withLock { values.removeValue(forKey: account) }
	}

	func deleteAll(accountPrefix: String) throws {
		lock.withLock {
			values = values.filter { !$0.key.hasPrefix(accountPrefix) }
		}
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
