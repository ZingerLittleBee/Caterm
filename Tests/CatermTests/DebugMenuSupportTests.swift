#if DEBUG
import XCTest
@testable import Caterm
@testable import SessionStore
@testable import SSHCommandBuilder
@testable import KeychainStore

/// Tests for the debug-only menu helper that picks a target host for the
/// "Open Tab for First Host" command (⌃⌥⌘O). The helper exists so UI
/// automation (Computer Use / cliclick / osascript) has a reliable AX-level
/// hook into the same `connect(_:)` path the sidebar's double-click uses,
/// without having to drive a SwiftUI List row.
@MainActor
final class DebugMenuSupportTests: XCTestCase {
	var sut: SessionStore!
	var tmpHostsURL: URL!
	var ephemeralService: String!

	override func setUp() async throws {
		ephemeralService = "com.caterm.test.\(UUID().uuidString)"
		tmpHostsURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-debug-menu-\(UUID()).json")
		let kc = KeychainStore(service: ephemeralService, accessGroup: nil)
		sut = SessionStore(
			askpassPath: "/x", knownHostsCaterm: "/A",
			knownHostsUser: "/B", accessGroup: nil,
			hostsURL: tmpHostsURL, keychain: kc
		)
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: tmpHostsURL)
		if let kc = sut?.keychain {
			try? kc.deleteAll(prefix: "")
		}
	}

	func testEmptyHostListReturnsNil() async {
		let target = await debugPickConnectTarget(in: sut)
		XCTAssertNil(target)
	}

	func testSingleUnlockedHostIsPicked() async throws {
		let h = SSHHost(name: "unlocked", hostname: "a", port: 22,
		                username: "u", credential: .agent)
		try sut.addHost(h)

		let target = await debugPickConnectTarget(in: sut)
		XCTAssertEqual(target?.id, h.id)
	}

	/// When all hosts need credential setup we still return the first one,
	/// so testers see the credential sheet pop instead of getting silent
	/// no-op. This makes the menu hook diagnostic on its own.
	func testAllLockedHostsReturnsFirstOverall() async throws {
		let locked1 = SSHHost(
			id: UUID(), serverId: "srv-1",
			name: "remote-1", hostname: "h", port: 22, username: "u",
			credential: .password
		)
		let locked2 = SSHHost(
			id: UUID(), serverId: "srv-2",
			name: "remote-2", hostname: "h", port: 22, username: "u",
			credential: .password
		)
		try sut.addHost(locked1)
		try sut.addHost(locked2)

		let target = await debugPickConnectTarget(in: sut)
		XCTAssertEqual(target?.id, locked1.id)
	}

	/// Mixed list: prefer the first unlocked host even if a locked host
	/// appears earlier. This is the common Computer Use scenario — a synced
	/// host without local secrets sitting next to a fully provisioned one.
	func testMixedListPrefersFirstUnlocked() async throws {
		let locked = SSHHost(
			id: UUID(), serverId: "srv-1",
			name: "locked", hostname: "h", port: 22, username: "u",
			credential: .password
		)
		let unlocked = SSHHost(name: "unlocked", hostname: "a", port: 22,
		                       username: "u", credential: .agent)
		try sut.addHost(locked)
		try sut.addHost(unlocked)

		let target = await debugPickConnectTarget(in: sut)
		XCTAssertEqual(target?.id, unlocked.id)
	}
}
#endif
