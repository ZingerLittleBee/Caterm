import CredentialIdentityRuntime
import CredentialIdentitySecurity
import CredentialIdentityStore
import Foundation
import SSHCommandBuilder
import Testing

struct CredentialIdentityConnectionResolverTests {
	@Test
	func oneIdentityResolvesForMultipleHostsWithoutChangingRouting() throws {
		let identity = CredentialIdentity(
			name: "Shared Production",
			username: "deploy",
			source: .password(materialID: CredentialMaterialID())
		)
		let first = host(
			name: "API",
			hostname: "api.example",
			identityID: identity.id
		)
		let second = host(
			name: "DB",
			hostname: "db.example",
			identityID: identity.id
		)
		let material = CredentialIdentityMaterial(
			password: Data("secret".utf8)
		)

		let firstResolved = try CredentialIdentityConnectionResolver.resolve(
			host: first,
			identities: [identity],
			material: material
		)
		let secondResolved = try CredentialIdentityConnectionResolver.resolve(
			host: second,
			identities: [identity],
			material: material
		)

		#expect(firstResolved.host.username == "deploy")
		#expect(secondResolved.host.username == "deploy")
		#expect(firstResolved.host.hostname == "api.example")
		#expect(secondResolved.host.hostname == "db.example")
		#expect(firstResolved.host.port == first.port)
		#expect(secondResolved.host.port == second.port)
		#expect(firstResolved.host.jumpHostId == first.jumpHostId)
		#expect(secondResolved.host.jumpHostId == second.jumpHostId)
		#expect(firstResolved.host.forwards == first.forwards)
		#expect(secondResolved.host.forwards == second.forwards)
		#expect(firstResolved.payload == .password(Data("secret".utf8)))
		#expect(secondResolved.payload == .password(Data("secret".utf8)))
	}

	@Test
	func updatedIdentityOnlyAffectsNewResolutionSnapshots() throws {
		let materialID = CredentialMaterialID()
		let original = CredentialIdentity(
			name: "Operations",
			username: "old-user",
			source: .password(materialID: materialID)
		)
		var updated = original
		updated.username = "new-user"
		let host = host(
			name: "Host",
			hostname: "host.example",
			identityID: original.id
		)
		let material = CredentialIdentityMaterial(
			password: Data("secret".utf8)
		)

		let existingSession =
			try CredentialIdentityConnectionResolver.resolve(
				host: host,
				identities: [original],
				material: material
			)
		let subsequentSession =
			try CredentialIdentityConnectionResolver.resolve(
				host: host,
				identities: [updated],
				material: material
			)

		#expect(existingSession.host.username == "old-user")
		#expect(subsequentSession.host.username == "new-user")
	}

	@Test
	func legacyHostRemainsUnchangedWithoutAssignment() throws {
		let legacy = SSHHost(
			name: "Legacy",
			hostname: "legacy.example",
			username: "root",
			credential: .password
		)

		let resolved = try CredentialIdentityConnectionResolver.resolve(
			host: legacy,
			identities: [],
			material: nil
		)

		#expect(resolved.host == legacy)
		#expect(resolved.identity == nil)
		#expect(resolved.payload == .legacyHostOwned)
	}

	@Test
	func certificateKeepsPublicAndPrivateHalvesTogether() throws {
		let certificate = Data("ssh-ed25519-cert-v01@openssh.com AAAA".utf8)
		let privateKey = Data("private".utf8)
		let identity = CredentialIdentity(
			name: "Certified",
			username: "cert-user",
			source: .sshCertificate(
				materialID: CredentialMaterialID(),
				publicCertificate: certificate,
				hasPassphrase: false
			)
		)

		let resolved = try CredentialIdentityConnectionResolver.resolve(
			host: host(
				name: "Certified Host",
				hostname: "cert.example",
				identityID: identity.id
			),
			identities: [identity],
			material: CredentialIdentityMaterial(privateKey: privateKey)
		)

		#expect(resolved.payload == .managedKey(
			privateKey: privateKey,
			passphrase: nil,
			publicCertificate: certificate
		))
	}

	@Test
	func remoteSecureEnclaveIdentityDoesNotFallBackToLegacyPassword() {
		let identity = CredentialIdentity(
			name: "Other Device",
			username: "admin",
			source: .secureEnclaveP256(
				materialID: CredentialMaterialID(),
				publicKey: Data([4, 5, 6]),
				originDeviceID: UUID()
			)
		)
		let assignedHost = host(
			name: "Secure",
			hostname: "secure.example",
			identityID: identity.id,
			migrationState: .confirmed
		)

		#expect(throws:
			CredentialIdentityResolutionError.secureEnclaveUnavailable(
				identity.id
			)
		) {
			try CredentialIdentityConnectionResolver.resolve(
				host: assignedHost,
				identities: [identity],
				material: CredentialIdentityMaterial()
			)
		}
	}

	@Test
	func reversibleMigrationFallsBackToHostOwnedCredential() throws {
		let identityID = UUID()
		let assignedHost = host(
			name: "Reversible",
			hostname: "fallback.example",
			identityID: identityID,
			migrationState: .reversible
		)

		let resolved = try CredentialIdentityConnectionResolver.resolve(
			host: assignedHost,
			identities: [],
			material: nil
		)

		#expect(resolved.identity == nil)
		#expect(resolved.payload == .legacyHostOwned)
		#expect(resolved.host == assignedHost)
	}

	private func host(
		name: String,
		hostname: String,
		identityID: UUID,
		migrationState:
			HostCredentialIdentityReference.MigrationState = .reversible
	) -> SSHHost {
		SSHHost(
			name: name,
			hostname: hostname,
			port: 2202,
			username: "legacy-user",
			credential: .password,
			jumpHostId: UUID(),
			forwards: [
				PortForward(
					kind: .local,
					bindPort: 8080,
					remoteHost: "127.0.0.1",
					remotePort: 80
				),
			],
			credentialIdentity: HostCredentialIdentityReference(
				identityID: identityID,
				migrationState: migrationState
			)
		)
	}
}
