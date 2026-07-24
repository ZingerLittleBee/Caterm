import XCTest
@testable import SSHCommandBuilder

final class ControlMasterTests: XCTestCase {
	func testControlMasterOptionsPresentForPasswordHost() {
		let host = Host(
			id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
			name: "demo", hostname: "h.example", port: 22,
			username: "alice", credential: .password
		)
		let out = SSHCommandBuilder._build(
			host: host,
			askpassPath: "/tmp/askpass",
			knownHostsCaterm: "/tmp/caterm_kh",
			knownHostsUser: "/tmp/user_kh",
			installTerminfo: false,
			sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)
		XCTAssertTrue(out.command.contains("-o 'ControlMaster=auto'"))
		XCTAssertTrue(out.command.contains("-o 'ControlPersist=10m'"))
		XCTAssertTrue(out.command.contains("ControlPath="))
		XCTAssertTrue(out.command.contains("11111111-1111-1111-1111-111111111111"))
	}

	func testExplicitControlPathOverridesHomeRelativeDefault() throws {
		let host = Host(
			id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
			name: "demo", hostname: "h.example", port: 22,
			username: "alice", credential: .password
		)
		let path = "/tmp/caterm isolated/cm/\(host.id.uuidString).sock"
		let out = try SSHCommandBuilder.buildValidated(
			host: host,
			askpassPath: "/tmp/askpass",
			knownHostsCaterm: "/tmp/caterm_kh",
			knownHostsUser: "/tmp/user_kh",
			controlPath: path
		)

		XCTAssertTrue(out.command.contains("'ControlPath=\"\(path)\"'"))
		XCTAssertFalse(out.command.contains("~/Library/Caches/Caterm/cm/"))
	}
}
