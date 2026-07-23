import XCTest
import SettingsStore
@testable import BackupArchive

final class BackupEnvelopeTests: XCTestCase {
	/// Cheapest in-bounds scrypt cost so the suite stays fast; production
	/// uses `.fresh()` (N=2^17).
	private func fastKDF() -> ScryptParameters {
		ScryptParameters(name: "scrypt", n: 1 << 14, r: 8, p: 1,
		                 salt: Data.random(count: 32))
	}

	func test_roundTrip() throws {
		let payload = Data("hello backup".utf8)
		let sealed = try BackupArchive.seal(payload: payload, passphrase: "correct horse",
		                                    kdf: fastKDF())
		XCTAssertEqual(try BackupArchive.open(sealed, passphrase: "correct horse"), payload)
	}

	func test_wrongPassphrase_isDistinguishedFromCorruption() throws {
		let sealed = try BackupArchive.seal(payload: Data("x".utf8), passphrase: "right",
		                                    kdf: fastKDF())
		XCTAssertThrowsError(try BackupArchive.open(sealed, passphrase: "wrong")) { error in
			XCTAssertEqual(error as? BackupArchiveError, .wrongPassphrase)
		}
	}

	func test_tamperedPayload_reportsCorruptNotWrongPassphrase() throws {
		let sealed = try BackupArchive.seal(payload: Data("payload".utf8),
		                                    passphrase: "pw", kdf: fastKDF())
		var envelope = try JSONDecoder().decode(BackupEnvelope.self, from: sealed)
		envelope.ciphertext[0] ^= 0xFF
		let tampered = try JSONEncoder().encode(envelope)
		XCTAssertThrowsError(try BackupArchive.open(tampered, passphrase: "pw")) { error in
			guard case .corruptArchive = error as? BackupArchiveError else {
				return XCTFail("expected corruptArchive, got \(error)")
			}
		}
	}

	func test_tamperedKDFParams_failAuthentication() throws {
		// Cost-downgrade attempt: header is AAD, so lowering n must break
		// key validation (surfacing as wrongPassphrase — the derived key
		// no longer matches, exactly as designed).
		let sealed = try BackupArchive.seal(payload: Data("payload".utf8),
		                                    passphrase: "pw", kdf: fastKDF())
		var envelope = try JSONDecoder().decode(BackupEnvelope.self, from: sealed)
		envelope.kdf.n = 1 << 15
		let tampered = try JSONEncoder().encode(envelope)
		XCTAssertThrowsError(try BackupArchive.open(tampered, passphrase: "pw"))
	}

	func test_outOfBoundsKDFParams_rejectedBeforeDerivation() throws {
		let sealed = try BackupArchive.seal(payload: Data("x".utf8), passphrase: "pw",
		                                    kdf: fastKDF())
		var envelope = try JSONDecoder().decode(BackupEnvelope.self, from: sealed)
		envelope.kdf.n = 1 << 30 // memory bomb
		let bomb = try JSONEncoder().encode(envelope)
		XCTAssertThrowsError(try BackupArchive.open(bomb, passphrase: "pw")) { error in
			XCTAssertEqual(error as? BackupArchiveError,
			               .corruptArchive(reason: "KDF parameters out of range"))
		}
	}

	func test_garbageInput_reportsNotABackupFile() {
		XCTAssertThrowsError(try BackupArchive.open(Data("junk".utf8), passphrase: "pw")) { error in
			XCTAssertEqual(error as? BackupArchiveError,
			               .corruptArchive(reason: "not a Caterm backup file"))
		}
	}

	func test_unsupportedFormatVersion_rejected() throws {
		let sealed = try BackupArchive.seal(payload: Data("x".utf8), passphrase: "pw",
		                                    kdf: fastKDF())
		var envelope = try JSONDecoder().decode(BackupEnvelope.self, from: sealed)
		envelope.formatVersion = 99
		let future = try JSONEncoder().encode(envelope)
		XCTAssertThrowsError(try BackupArchive.open(future, passphrase: "pw")) { error in
			XCTAssertEqual(error as? BackupArchiveError, .unsupportedFormatVersion(99))
		}
	}

	func test_freshKDF_usesApprovedCostTier() {
		let kdf = ScryptParameters.fresh()
		XCTAssertEqual(kdf.n, 1 << 17)
		XCTAssertEqual(kdf.r, 8)
		XCTAssertEqual(kdf.p, 1)
		XCTAssertEqual(kdf.salt.count, 32)
	}

	func test_saltAndNonces_freshPerSeal() throws {
		let a = try JSONDecoder().decode(BackupEnvelope.self, from:
			BackupArchive.seal(payload: Data("x".utf8), passphrase: "pw", kdf: fastKDF()))
		let b = try JSONDecoder().decode(BackupEnvelope.self, from:
			BackupArchive.seal(payload: Data("x".utf8), passphrase: "pw", kdf: fastKDF()))
		XCTAssertNotEqual(a.kdf.salt, b.kdf.salt)
		XCTAssertNotEqual(a.nonce, b.nonce)
	}

	func test_randomPassphrase_shapeAndUniqueness() {
		let p = BackupArchive.randomPassphrase()
		XCTAssertEqual(p.count, 23) // 4 groups × 5 + 3 separators
		XCTAssertEqual(p.split(separator: "-").count, 4)
		XCTAssertNotEqual(p, BackupArchive.randomPassphrase())
	}

	func test_payload_roundTrip() throws {
		let hostId = UUID()
		let snippetID = UUID()
		let identityID = UUID()
		let materialID = UUID()
		let payload = BackupPayload(
			exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
			appVersion: "2.0",
			hosts: [BackupHost(
				id: hostId, serverId: "srv-1", name: "web", hostname: "example.com",
				port: 2222, username: "root", credentialKind: "keyFile",
				hasPassphrase: true,
				createdAt: Date(timeIntervalSince1970: 1_600_000_000),
				updatedAt: Date(timeIntervalSince1970: 1_650_000_000),
				jumpHostId: nil,
				forwards: [BackupPortForward(kind: "local", bindPort: 8080,
				                             remoteHost: "localhost", remotePort: 80,
				                             required: true)],
				icon: "server.rack",
				automation: BackupHostAutomation(
					isEnabled: true,
					startupSnippetID: snippetID,
					environment: [
						BackupHostEnvironmentVariable(
							id: UUID(),
							name: "REGION",
							value: "west"
						)
					],
					reviewPolicy: "always",
					reconnectPolicy: "oncePerSession"
				),
				credentialIdentity: BackupHostCredentialIdentityReference(
					identityID: identityID,
					migrationState: "reversible"
				),
				password: nil, passphrase: "pp", privateKey: Data("KEY".utf8)
			)],
			credentialIdentities: [
				BackupCredentialIdentity(
					kind: "sshCertificate",
					id: identityID,
					serverId: identityID.uuidString,
					materialId: materialID,
					name: "Production",
					username: "deploy",
					hasPassphrase: true,
					publicCertificate: Data("CERT".utf8),
					createdAt: Date(timeIntervalSince1970: 10),
					updatedAt: Date(timeIntervalSince1970: 20),
					passphrase: Data("pp".utf8),
					privateKey: Data("PRIVATE".utf8)
				)
			],
			snippets: [BackupSnippet(id: snippetID, name: "ls", content: "ls -la",
			                         placeholders: nil,
			                         createdAt: Date(timeIntervalSince1970: 0),
			                         updatedAt: Date(timeIntervalSince1970: 1))],
			settings: BackupSettings(revision: "r1", global: PartialSettings(),
			                         hostOverrides: [hostId.uuidString: PartialSettings()]),
			bookmarks: [BackupBookmark(id: UUID(), hostId: hostId, label: "www",
			                           path: "/var/www",
			                           createdAt: Date(timeIntervalSince1970: 2))],
			knownHosts: ["example.com ssh-ed25519 AAAA..."]
		)
		let decoded = try BackupPayload.decode(payload.encoded())
		XCTAssertEqual(decoded, payload)
	}

	func test_legacyBackupHostWithoutAutomationDecodesWithNilMetadata() throws {
		let hostID = UUID()
		let json = """
		{
		  "contentVersion": 1,
		  "exportedAt": "2026-07-23T00:00:00Z",
		  "hosts": [{
		    "id": "\(hostID.uuidString)",
		    "name": "Legacy",
		    "hostname": "legacy.example",
		    "port": 22,
		    "username": "deploy",
		    "credentialKind": "password",
		    "hasPassphrase": false,
		    "createdAt": "2026-07-22T00:00:00Z",
		    "updatedAt": "2026-07-22T00:00:00Z",
		    "forwards": []
		  }],
		  "snippets": [],
		  "bookmarks": [],
		  "knownHosts": []
		}
		""".data(using: .utf8)!

		let payload = try BackupPayload.decode(json)

		XCTAssertNil(payload.hosts.first?.automation)
		XCTAssertTrue(payload.credentialIdentities.isEmpty)
		XCTAssertNil(payload.hosts.first?.credentialIdentity)
	}

	func test_payload_futureContentVersion_rejected() throws {
		var payload = BackupPayload(exportedAt: Date())
		payload.contentVersion = 99
		XCTAssertThrowsError(try BackupPayload.decode(payload.encoded())) { error in
			XCTAssertEqual(error as? BackupArchiveError, .unsupportedFormatVersion(99))
		}
	}

	func test_envelope_fullPayload_endToEnd() throws {
		let payload = BackupPayload(exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
		                            knownHosts: ["a", "b"])
		let sealed = try BackupArchive.seal(payload: payload.encoded(),
		                                    passphrase: "pw12345678", kdf: fastKDF())
		let opened = try BackupPayload.decode(try BackupArchive.open(sealed, passphrase: "pw12345678"))
		XCTAssertEqual(opened, payload)
	}
}
