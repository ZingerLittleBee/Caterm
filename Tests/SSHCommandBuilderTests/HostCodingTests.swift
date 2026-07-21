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
		XCTAssertEqual(h.organization, .empty)
	}

	func test_hostOrganization_normalizesGroupPathAndTags() {
		let organization = HostOrganization(
			groupPath: [" Production ", "", " API "],
			tags: [" Linux ", "prod", "linux", "", "PROD"]
		)

		XCTAssertEqual(organization.groupPath, ["Production", "API"])
		XCTAssertEqual(organization.tags, ["Linux", "prod"])
		XCTAssertEqual(organization.groupDisplayName, "Production / API")
	}

	func test_hostOrganization_roundTripsWithHost() throws {
		let host = Host(
			name: "API", hostname: "api.example", username: "deploy",
			credential: .agent,
			organization: HostOrganization(
				groupPath: ["Production", "Services"],
				tags: ["Linux", "Critical"]
			)
		)

		let data = try JSONEncoder().encode(host)
		let decoded = try JSONDecoder().decode(Host.self, from: data)

		XCTAssertEqual(decoded.organization, host.organization)
	}
}
