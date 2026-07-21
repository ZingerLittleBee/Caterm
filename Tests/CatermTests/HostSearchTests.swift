import XCTest
@testable import Caterm
@testable import SSHCommandBuilder

final class HostSearchTests: XCTestCase {
	func testFilterMatchesEveryVisibleHostIdentityFieldCaseInsensitively() {
		let hosts = [
			SSHHost(
				name: "Production API", hostname: "api.example.com", port: 2202,
				username: "deploy", credential: .agent
			),
			SSHHost(
				name: "Database", hostname: "db.internal", port: 22,
				username: "postgres", credential: .agent
			),
		]

		XCTAssertEqual(HostSearch.filter(hosts, query: "PRODUCTION").map(\.name), ["Production API"])
		XCTAssertEqual(HostSearch.filter(hosts, query: "api.example").map(\.name), ["Production API"])
		XCTAssertEqual(HostSearch.filter(hosts, query: "DEPLOY").map(\.name), ["Production API"])
		XCTAssertEqual(HostSearch.filter(hosts, query: "2202").map(\.name), ["Production API"])
	}

	func testFilterTreatsBlankQueryAsNoFilterAndPreservesOrder() {
		let hosts = [
			SSHHost(name: "Second", hostname: "b.example", username: "b", credential: .agent),
			SSHHost(name: "First", hostname: "a.example", username: "a", credential: .agent),
		]

		XCTAssertEqual(HostSearch.filter(hosts, query: "  \n").map(\.name), ["Second", "First"])
	}

	func testFilterMatchesSSHStyleDestination() {
		let hosts = [
			SSHHost(
				name: "Production API", hostname: "api.example.com", port: 2202,
				username: "deploy", credential: .agent
			),
			SSHHost(
				name: "Production API read-only", hostname: "api.example.com", port: 22,
				username: "reader", credential: .agent
			),
		]

		XCTAssertEqual(
			HostSearch.filter(hosts, query: "deploy@api.example.com:2202").map(\.name),
			["Production API"]
		)
	}
}
