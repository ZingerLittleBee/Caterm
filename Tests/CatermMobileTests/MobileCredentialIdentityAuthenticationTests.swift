import CatermMobileTerminal
import CredentialIdentitySecurity
import CredentialIdentityStore
import CredentialSyncStore
import Foundation
import ManagedKeyStore
import SessionStore
import SSHCommandBuilder
import Testing
@testable import CatermMobile

@Suite(.serialized)
struct MobileCredentialIdentityAuthenticationTests {
	@Test
	func sharedPasswordOverridesLegacyUsernameAndCredential()
		async throws {
		let fixture = try MobileIdentityAuthenticationFixture()
		let identity = CredentialIdentity(
			name: "Shared operations",
			username: "identity-user",
			source: .password(
				materialID: CredentialMaterialID()
			)
		)
		try await fixture.materialStore.replaceMaterial(
			for: identity,
			with: .init(
				password: Data("identity-password".utf8)
			)
		)
		let result = await fixture.provider(
			identity: identity
		).resolve(
			host: fixture.host(assignedTo: identity.id),
			credentialSyncState: .enabled
		)
		let authentication = try #require(
			result.availableValue
		)

		#expect(authentication.host.username == "identity-user")
		#expect(
			authentication.plan.attempts
				== [.password("identity-password")]
		)
	}

	@Test
	func certificateKeepsPrivateKeyAndPublicCertificatePaired()
		async throws {
		let fixture = try MobileIdentityAuthenticationFixture()
		let materialID = CredentialMaterialID()
		let certificate = Data(
			"ssh-ed25519-cert-v01@openssh.com AAAA test".utf8
		)
		let privateKey = Data("private-key".utf8)
		let identity = CredentialIdentity(
			name: "Certificate",
			username: "cert-user",
			source: .sshCertificate(
				materialID: materialID,
				publicCertificate: certificate,
				hasPassphrase: true
			)
		)
		try await fixture.materialStore.replaceMaterial(
			for: identity,
			with: .init(
				passphrase: Data("phrase".utf8),
				privateKey: privateKey
			)
		)
		let result = await fixture.provider(
			identity: identity
		).resolve(
			host: fixture.host(assignedTo: identity.id),
			credentialSyncState: .enabled
		)
		let authentication = try #require(
			result.availableValue
		)

		#expect(
			authentication.plan.attempts
				== [
					.certifiedPrivateKey(
						blob: privateKey,
						passphrase: "phrase",
						publicCertificate: certificate
					),
				]
		)
	}

	@Test
	func remoteDeviceBoundIdentityNeverFallsBackToLegacyPassword()
		async throws {
		let fixture = try MobileIdentityAuthenticationFixture()
		let identity = CredentialIdentity(
			name: "Device key",
			username: "secure-user",
			source: .secureEnclaveP256(
				materialID: CredentialMaterialID(),
				publicKey: Data([1, 2, 3]),
				originDeviceID: UUID()
			)
		)

		let result = await fixture.provider(
			identity: identity
		).resolve(
			host: fixture.host(assignedTo: identity.id),
			credentialSyncState: .enabled
		)

		#expect(
			result == .unavailable(
				.deviceBoundPrivateKeyUnavailable
			)
		)
	}
}

private struct MobileIdentityAuthenticationFixture {
	let legacyMaterialStore: SessionCredentialMaterialStore
	let materialStore: CredentialIdentityMaterialStore

	init() throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		let managedKeys = ManagedKeyStore(
			rootURL: root.appendingPathComponent("keys")
		)
		legacyMaterialStore = SessionCredentialMaterialStore(
			keychainService: "com.caterm.test.legacy.\(UUID())",
			keychainAccessGroup: nil,
			managedKeyStore: managedKeys
		)
		materialStore = CredentialIdentityMaterialStore(
			secrets: MobileMemoryIdentitySecrets(),
			managedKeys: managedKeys,
			secureEnclave: MobileUnavailableSecureEnclave()
		)
	}

	func provider(
		identity: CredentialIdentity
	) -> MobileAuthenticationPlanProvider {
		MobileAuthenticationPlanProvider(
			materialStore: legacyMaterialStore,
			identityMaterialStore: materialStore,
			identity: { id in
				id == identity.id ? identity : nil
			}
		)
	}

	func host(assignedTo identityID: UUID) -> SSHHost {
		var host = SSHHost(
			name: "Server",
			hostname: "server.example.com",
			port: 22,
			username: "legacy-user",
			credential: .password
		)
		host.credentialIdentity = .init(
			identityID: identityID,
			migrationState: .reversible
		)
		return host
	}
}

private extension MobileAuthenticationPlanResult {
	var availableValue: MobilePreparedAuthentication? {
		guard case .available(let value) = self else {
			return nil
		}
		return value
	}
}

private final class MobileMemoryIdentitySecrets:
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

private struct MobileUnavailableSecureEnclave:
	SecureEnclaveIdentityKeyProviding {
	var isAvailable: Bool { false }

	func create(
		localizedReason: String
	) throws -> SecureEnclaveIdentityKey {
		throw SecureEnclaveIdentityError.unavailable
	}

	func restore(
		dataRepresentation: Data,
		localizedReason: String
	) throws -> SecureEnclaveIdentityKey {
		throw SecureEnclaveIdentityError.unavailable
	}
}
