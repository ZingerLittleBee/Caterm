import SSHCommandBuilder
import XCTest
@testable import Caterm

final class PortForwardWorkspaceTests: XCTestCase {
	func testRowsFlattenHostsAndDescribeEveryForwardKind() {
		let host = SSHHost(
			name: "Production",
			hostname: "prod.example.com",
			username: "deploy",
			credential: .agent,
			forwards: [
				PortForward(
					kind: .local,
					bindAddress: "127.0.0.1",
					bindPort: 5432,
					remoteHost: "db.internal",
					remotePort: 5432,
					label: "PostgreSQL"
				),
				PortForward(
					kind: .remote,
					bindPort: 8080,
					remoteHost: "localhost",
					remotePort: 3000,
					required: false
				),
				PortForward(kind: .dynamic, bindPort: 1080),
			]
		)

		let rows = PortForwardWorkspaceModel.rows(hosts: [host], query: "")

		XCTAssertEqual(rows.map(\.hostName), ["Production", "Production", "Production"])
		XCTAssertEqual(
			rows.map(\.ruleName),
			["PostgreSQL", "Remote forwarding", "Dynamic forwarding"]
		)
		XCTAssertEqual(rows.map(\.kindText), ["Local", "Remote", "Dynamic"])
		XCTAssertEqual(
			rows.map(\.listenAddress),
			["127.0.0.1:5432", "localhost:8080", "localhost:1080"]
		)
		XCTAssertEqual(
			rows.map(\.destination),
			["db.internal:5432", "localhost:3000", "SOCKS proxy"]
		)
		XCTAssertEqual(rows.map(\.requiredText), ["Required", "Optional", "Required"])
	}

	func testRowsSearchAcrossHostAndEndpoints() {
		let databaseHost = SSHHost(
			name: "Database",
			hostname: "db.example.com",
			username: "alice",
			credential: .agent,
			forwards: [
				PortForward(
					kind: .local,
					bindPort: 15432,
					remoteHost: "postgres.internal",
					remotePort: 5432
				)
			]
		)
		let webHost = SSHHost(
			name: "Web",
			hostname: "web.example.com",
			username: "bob",
			credential: .agent,
			forwards: [PortForward(kind: .dynamic, bindPort: 1080)]
		)

		XCTAssertEqual(
			PortForwardWorkspaceModel.rows(
				hosts: [databaseHost, webHost],
				query: "POSTGRES"
			).map(\.hostID),
			[databaseHost.id]
		)
		XCTAssertEqual(
			PortForwardWorkspaceModel.rows(
				hosts: [databaseHost, webHost],
				query: "1080"
			).map(\.hostID),
			[webHost.id]
		)
	}
}
