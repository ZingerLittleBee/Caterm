import XCTest
@testable import SSHCommandBuilder

final class HostBackwardCompatTests: XCTestCase {
	func testDecodesV1JSONWithoutServerId() throws {
		let v1Json = #"""
		{
		    "id": "11111111-1111-1111-1111-111111111111",
		    "name": "prod",
		    "hostname": "1.2.3.4",
		    "port": 22,
		    "username": "root",
		    "credential": {"password": {}},
		    "createdAt": 770000000,
		    "updatedAt": 770000000
		}
		"""#
		let host = try JSONDecoder().decode(Host.self, from: Data(v1Json.utf8))
		XCTAssertNil(host.serverId)
		XCTAssertEqual(host.name, "prod")
	}

	func testEncodesAndDecodesServerIdWhenPresent() throws {
		var host = Host(name: "h", hostname: "x", username: "u", credential: .agent)
		host.serverId = "srv-abc"
		let data = try JSONEncoder().encode(host)
		let decoded = try JSONDecoder().decode(Host.self, from: data)
		XCTAssertEqual(decoded.serverId, "srv-abc")
	}
}
