import XCTest
@testable import SSHCommandBuilder

final class HostJumpHostServerIdTests: XCTestCase {
	func testDefaultInitHasNilJumpHostServerId() {
		let h = SSHHost(name: "n", hostname: "h", port: 22,
		                username: "u", credential: .password)
		XCTAssertNil(h.jumpHostServerId)
	}

	func testCodableRoundTripWithNonNilJumpHostServerId() throws {
		var h = SSHHost(name: "n", hostname: "h", port: 22,
		                username: "u", credential: .password)
		h.jumpHostServerId = "server-abc-123"
		let data = try JSONEncoder().encode(h)
		let decoded = try JSONDecoder().decode(SSHHost.self, from: data)
		XCTAssertEqual(decoded.jumpHostServerId, "server-abc-123")
	}

	func testCodableDecodesLegacyPayloadWithoutJumpHostServerIdAsNil() throws {
		// A payload written by the previous version of the app — no
		// jumpHostServerId key at all. Decoding must succeed and yield nil.
		let legacy = #"""
		{
		  "id": "11111111-2222-3333-4444-555555555555",
		  "name": "n",
		  "hostname": "h",
		  "port": 22,
		  "username": "u",
		  "credential": {"password": {}},
		  "createdAt": 770000000,
		  "updatedAt": 770000000
		}
		"""#
		let decoded = try? JSONDecoder().decode(SSHHost.self,
		                                       from: Data(legacy.utf8))
		XCTAssertNotNil(decoded, "Legacy payload must still decode")
		XCTAssertNil(decoded?.jumpHostServerId)
	}

	func testEncoderOmitsKeyWhenJumpHostServerIdIsNil() throws {
		// Pin the contract that downstream wire-format key-absence checks
		// rely on: the synthesized encoder must not emit the key when nil.
		let h = SSHHost(name: "n", hostname: "h", port: 22,
		                username: "u", credential: .password)
		let json = String(data: try JSONEncoder().encode(h), encoding: .utf8)!
		XCTAssertFalse(json.contains("jumpHostServerId"),
		               "nil jumpHostServerId should be omitted, got: \(json)")
	}
}
