import Foundation
import SSHCommandBuilder
import Testing

struct HostCredentialIdentityReferenceTests {
	@Test
	func legacyHostDecodesWithoutIdentityReference() throws {
		let json = """
		{
		  "id": "00000000-0000-0000-0000-000000000001",
		  "name": "Legacy",
		  "hostname": "legacy.example",
		  "port": 22,
		  "username": "root",
		  "credential": {"password": {}},
		  "createdAt": 0,
		  "updatedAt": 0
		}
		"""

		let host = try JSONDecoder().decode(
			SSHHost.self,
			from: Data(json.utf8)
		)

		#expect(host.credentialIdentity == nil)
		#expect(host.username == "root")
		#expect(host.credential == .password)
	}

	@Test
	func reversibleAssignmentRoundTripsWithoutChangingRoutingMetadata() throws {
		let identityID = UUID()
		let host = SSHHost(
			name: "Production",
			hostname: "prod.example",
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
				migrationState: .reversible
			)
		)

		let decoded = try JSONDecoder().decode(
			SSHHost.self,
			from: JSONEncoder().encode(host)
		)

		#expect(decoded == host)
		#expect(decoded.hostname == "prod.example")
		#expect(decoded.port == 2202)
		#expect(decoded.jumpHostId == host.jumpHostId)
		#expect(decoded.forwards == host.forwards)
		#expect(decoded.username == "legacy-user")
		#expect(decoded.credential == .password)
	}
}
