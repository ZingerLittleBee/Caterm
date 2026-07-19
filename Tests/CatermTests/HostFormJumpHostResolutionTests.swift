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

		let selection = HostFormView.jumpHostSelectionForForm(
			host: edited,
			allHosts: [unsyncedParent, edited]
		)

		XCTAssertEqual(selection, .none)
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

		let selection = HostFormView.jumpHostSelectionForForm(
			host: edited,
			allHosts: [parent, edited]
		)

		XCTAssertEqual(
			selection,
			.resolved(localID: parent.id)
		)
	}

	func testStaleLocalReferenceFallsBackToStableServerReference() {
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
		edited.jumpHostId = UUID()
		edited.jumpHostServerId = parent.serverId

		let selection = HostFormView.jumpHostSelectionForForm(
			host: edited,
			allHosts: [parent, edited]
		)

		XCTAssertEqual(
			selection,
			.resolved(localID: parent.id)
		)
	}

	func testMissingServerReferenceIsRetainedForFormDiagnostic() {
		var edited = SSHHost(
			name: "target",
			hostname: "target.example.com",
			username: "root",
			credential: .password
		)
		edited.jumpHostServerId = "deleted-server-id"

		let selection = HostFormView.jumpHostSelectionForForm(
			host: edited,
			allHosts: [edited]
		)

		XCTAssertEqual(
			selection,
			.unresolved(.serverID("deleted-server-id"))
		)
	}

	func testValidLocalReferenceWinsOverDifferentServerReference() {
		var localParent = SSHHost(
			name: "local-parent",
			hostname: "local.example.com",
			username: "root",
			credential: .password
		)
		localParent.serverId = "local-server-id"
		var serverParent = SSHHost(
			name: "server-parent",
			hostname: "server.example.com",
			username: "root",
			credential: .password
		)
		serverParent.serverId = "different-server-id"
		var edited = SSHHost(
			name: "target",
			hostname: "target.example.com",
			username: "root",
			credential: .password
		)
		edited.jumpHostId = localParent.id
		edited.jumpHostServerId = serverParent.serverId

		let selection = HostFormView.jumpHostSelectionForForm(
			host: edited,
			allHosts: [localParent, serverParent, edited]
		)

		XCTAssertEqual(
			selection,
			.resolved(localID: localParent.id)
		)
	}

	func testResolvedSelectionDerivesLatestServerReferenceAtPersistenceTime() {
		var parent = SSHHost(
			name: "parent",
			hostname: "jump.example.com",
			username: "root",
			credential: .password
		)
		let selection = HostFormView.JumpHostSelection.resolved(localID: parent.id)

		let beforeSync = selection.reference(among: [parent])
		XCTAssertEqual(beforeSync.localID, parent.id)
		XCTAssertNil(beforeSync.serverID)

		parent.serverId = "parent-server-id"
		let afterSync = selection.reference(among: [parent])
		XCTAssertEqual(afterSync.localID, parent.id)
		XCTAssertEqual(afterSync.serverID, "parent-server-id")
	}

	func testUnresolvedServerSelectionNormalizesWhenParentArrives() {
		let selection = HostFormView.JumpHostSelection.unresolved(
			.serverID("parent-server-id")
		)
		XCTAssertEqual(selection.normalized(among: []), selection)

		var parent = SSHHost(
			name: "parent",
			hostname: "jump.example.com",
			username: "root",
			credential: .password
		)
		parent.serverId = "parent-server-id"

		XCTAssertEqual(
			selection.normalized(among: [parent]),
			.resolved(localID: parent.id)
		)
		let reference = selection.reference(among: [parent])
		XCTAssertEqual(reference.localID, parent.id)
		XCTAssertEqual(reference.serverID, parent.serverId)
	}
}
