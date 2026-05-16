import SSHCommandBuilder
@testable import CatermMobile
import XCTest

final class MobileHostActionsTests: XCTestCase {
	func testConnectRoutesLockedHostsToCredentialSetup() {
		let host = SSHHost(
			id: UUID(),
			name: "Prod",
			hostname: "prod.example.com",
			username: "deploy",
			credential: .password
		)

		let route = MobileHostActions.connectRoute(for: host, needsCredentialSetup: true)

		XCTAssertEqual(route, .credentialSetup(host.id))
	}

	func testConnectRoutesReadyHostsToTerminalPlaceholder() {
		let host = SSHHost(
			id: UUID(),
			name: "Prod",
			hostname: "prod.example.com",
			username: "deploy",
			credential: .agent
		)

		let route = MobileHostActions.connectRoute(for: host, needsCredentialSetup: false)

		XCTAssertEqual(route, .terminalPlaceholder(host.id))
	}

	func testEditRoutesToHostEditor() {
		let host = SSHHost(
			id: UUID(),
			name: "Prod",
			hostname: "prod.example.com",
			username: "deploy",
			credential: .agent
		)

		XCTAssertEqual(MobileHostActions.editRoute(for: host), .edit(host.id))
	}

	func testDeleteCreatesConfirmationAction() {
		let host = SSHHost(
			id: UUID(),
			name: "Prod",
			hostname: "prod.example.com",
			username: "deploy",
			credential: .agent
		)

		XCTAssertEqual(MobileHostActions.deleteAction(for: host), .confirmDelete(host.id))
	}
}
