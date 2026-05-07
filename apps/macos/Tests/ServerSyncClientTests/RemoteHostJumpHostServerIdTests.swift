import XCTest
@testable import ServerSyncClient

final class RemoteHostJumpHostServerIdTests: XCTestCase {
	func testRemoteHostCodableRoundTripWithNonNilField() throws {
		let r = RemoteHost(
			id: "rh-1", name: "n", hostname: "h", port: 22,
			username: "u", authType: "key",
			createdAt: Date(timeIntervalSince1970: 0),
			updatedAt: Date(timeIntervalSince1970: 0),
			jumpHostServerId: "rh-bastion"
		)
		let data = try JSONEncoder().encode(r)
		let decoded = try JSONDecoder().decode(RemoteHost.self, from: data)
		XCTAssertEqual(decoded.jumpHostServerId, "rh-bastion")
	}

	func testRemoteHostDecodesLegacyPayloadWithoutFieldAsNil() throws {
		let legacy = #"""
		{
		  "id": "rh-1", "name": "n", "hostname": "h", "port": 22,
		  "username": "u", "authType": "key",
		  "createdAt": "1970-01-01T00:00:00Z",
		  "updatedAt": "1970-01-01T00:00:00Z"
		}
		"""#
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let r = try decoder.decode(RemoteHost.self, from: Data(legacy.utf8))
		XCTAssertNil(r.jumpHostServerId)
	}

	func testCreateInputEncodesJumpHostServerId() throws {
		let input = RemoteHostCreateInput(
			name: "n", hostname: "h", port: 22, username: "u",
			jumpHostServerId: "rh-bastion"
		)
		let data = try JSONEncoder().encode(input)
		let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		XCTAssertEqual(json?["jumpHostServerId"] as? String, "rh-bastion")
	}

	func testUpdateInputEncodesJumpHostServerId() throws {
		let input = RemoteHostUpdateInput(
			id: "rh-1", name: "n", hostname: "h", port: 22, username: "u",
			jumpHostServerId: "rh-bastion"
		)
		let data = try JSONEncoder().encode(input)
		let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		XCTAssertEqual(json?["jumpHostServerId"] as? String, "rh-bastion")
	}

	func testCreateInputOmitsFieldWhenNil() throws {
		let input = RemoteHostCreateInput(
			name: "n", hostname: "h", port: 22, username: "u"
		)
		let data = try JSONEncoder().encode(input)
		let str = String(data: data, encoding: .utf8) ?? ""
		// Either absent or explicit null; both are acceptable on the wire.
		// We want absent so server-side schemas without the column still parse.
		XCTAssertFalse(str.contains("\"jumpHostServerId\":\"") ,
		               "non-null jumpHostServerId leaked: \(str)")
	}
}
