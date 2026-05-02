import XCTest
import SSHCommandBuilder
import Foundation

final class HostCodableBackcompatTests: XCTestCase {
	func test_decode_legacyJsonWithoutDirtyKey_setsFalse() throws {
		let json = """
		{
		  "id": "11111111-2222-3333-4444-555555555555",
		  "name": "Box",
		  "hostname": "host.example",
		  "port": 22,
		  "username": "root",
		  "credential": {"password": {}},
		  "createdAt": -3600,
		  "updatedAt": 0
		}
		""".data(using: .utf8)!
		let host = try JSONDecoder().decode(Host.self, from: json)
		XCTAssertEqual(host.credentialMaterialDirty, false)
	}

	func test_roundTrip_dirtyTruePersists() throws {
		var host = Host(name: "Box", hostname: "h", port: 22, username: "u", credential: .password)
		host.credentialMaterialDirty = true
		let data = try JSONEncoder().encode(host)
		let decoded = try JSONDecoder().decode(Host.self, from: data)
		XCTAssertTrue(decoded.credentialMaterialDirty)
	}
}
