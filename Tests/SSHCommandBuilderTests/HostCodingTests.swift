import XCTest
@testable import SSHCommandBuilder

final class HostCodingTests: XCTestCase {
	func test_legacyHostJSON_withoutForwards_decodesToEmpty() throws {
		let legacyJSON = """
		{
		  "id": "\(UUID().uuidString)",
		  "name": "Legacy",
		  "hostname": "h.example.com",
		  "port": 22,
		  "username": "u",
		  "credential": { "password": {} },
		  "createdAt": 770000000,
		  "updatedAt": 770000000
		}
		""".data(using: .utf8)!
		let h = try JSONDecoder().decode(Host.self, from: legacyJSON)
		XCTAssertEqual(h.forwards, [])
	}
}
