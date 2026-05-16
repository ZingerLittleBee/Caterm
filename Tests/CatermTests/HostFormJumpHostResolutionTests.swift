import XCTest
@testable import Caterm
@testable import SSHCommandBuilder

final class HostFormJumpHostResolutionTests: XCTestCase {
	func testNilJumpHostServerIdDoesNotResolveFirstUnsyncedHost() {
		let unsyncedParent = SSHHost(
			name: "unsynced",
			hostname: "jump.example.com",
			username: "root",
			credential: .password
		)
		let edited = SSHHost(
			name: "target",
			hostname: "target.example.com",
			username: "root",
			credential: .password
		)

		let resolved = HostFormView.jumpHostIdForForm(
			host: edited,
			allHosts: [unsyncedParent, edited]
		)

		XCTAssertNil(resolved)
	}

	func testServerJumpHostReferenceResolvesToMatchingLocalHostId() {
		var parent = SSHHost(
			name: "parent",
			hostname: "jump.example.com",
			username: "root",
			credential: .password
		)
		parent.serverId = "parent-server-id"
		var edited = SSHHost(
			name: "target",
			hostname: "target.example.com",
			username: "root",
			credential: .password
		)
		edited.jumpHostServerId = parent.serverId

		let resolved = HostFormView.jumpHostIdForForm(
			host: edited,
			allHosts: [parent, edited]
		)

		XCTAssertEqual(resolved, parent.id)
	}
}
