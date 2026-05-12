import XCTest
@testable import SSHCommandBuilder

final class PortForwardSnapshotTests: XCTestCase {

	func test_local_noBindAddress_emitsBindPortOnly() throws {
		let f = PortForward(kind: .local, bindPort: 5432,
							remoteHost: "db.internal", remotePort: 5432)
		XCTAssertEqual(try f.sshConfigLine(),
					   "LocalForward 5432 db.internal:5432")
	}

	func test_local_withBindAddress_emitsAddrColonPort() throws {
		let f = PortForward(kind: .local, bindAddress: "*", bindPort: 5432,
							remoteHost: "db.internal", remotePort: 5432)
		XCTAssertEqual(try f.sshConfigLine(),
					   "LocalForward *:5432 db.internal:5432")
	}

	func test_remote_basic() throws {
		let f = PortForward(kind: .remote, bindPort: 9090,
							remoteHost: "localhost", remotePort: 9090)
		XCTAssertEqual(try f.sshConfigLine(),
					   "RemoteForward 9090 localhost:9090")
	}

	func test_dynamic_basic() throws {
		let f = PortForward(kind: .dynamic, bindPort: 1080)
		XCTAssertEqual(try f.sshConfigLine(), "DynamicForward 1080")
	}

	func test_dynamic_withBindAddress() throws {
		let f = PortForward(kind: .dynamic, bindAddress: "127.0.0.1", bindPort: 1080)
		XCTAssertEqual(try f.sshConfigLine(),
					   "DynamicForward 127.0.0.1:1080")
	}
}

extension PortForwardSnapshotTests {

	fileprivate func makeHost(forwards: [PortForward] = []) -> SSHHost {
		SSHHost(id: UUID(), name: "h", hostname: "h.example.com",
				port: 22, username: "u", credential: .password,
				forwards: forwards)
	}

	func test_chain_targetForwardsEmitted_inTargetBlock() throws {
		let target = makeHost(forwards: [
			PortForward(kind: .local, bindPort: 5432,
						remoteHost: "db", remotePort: 5432, required: true),
		])
		let jump = makeHost()
		let sink = InMemorySSHConfigSink()
		let out = try SSHCommandBuilder.build(
			host: target,
			ancestors: [jump],
			configSink: sink,
			askpassPath: "/tmp/askpass",
			knownHostsCaterm: "/tmp/known_caterm",
			knownHostsUser: "/tmp/known_user"
		)
		let cfg = sink.writes.last?.1 ?? ""
		// Target block must contain the forward.
		XCTAssertTrue(cfg.contains("LocalForward 5432 db:5432"))
		// ExitOnForwardFailure yes — all forwards required.
		XCTAssertTrue(cfg.contains("ExitOnForwardFailure yes"))
		// Jump block must NOT contain the forward.
		let jumpBlock = cfg.components(separatedBy: "\n\nHost caterm-h-").first ?? ""
		XCTAssertFalse(jumpBlock.contains("LocalForward"))
		_ = out
	}

	func test_chain_mixedRequiredAndOptional_noExitOnForwardFailure() throws {
		let target = makeHost(forwards: [
			PortForward(kind: .local, bindPort: 5432,
						remoteHost: "db", remotePort: 5432, required: true),
			PortForward(kind: .local, bindPort: 8080,
						remoteHost: "localhost", remotePort: 8080, required: false),
		])
		let sink = InMemorySSHConfigSink()
		_ = try SSHCommandBuilder.build(
			host: target, ancestors: [makeHost()],
			configSink: sink,
			askpassPath: "/tmp/a", knownHostsCaterm: "/tmp/k1", knownHostsUser: "/tmp/k2"
		)
		let cfg = sink.writes.last?.1 ?? ""
		XCTAssertTrue(cfg.contains("LocalForward 5432 db:5432"))
		XCTAssertTrue(cfg.contains("LocalForward 8080 localhost:8080"))
		XCTAssertFalse(cfg.contains("ExitOnForwardFailure"))
	}

	func test_chain_emptyForwards_noExitOnForwardFailure() throws {
		let sink = InMemorySSHConfigSink()
		_ = try SSHCommandBuilder.build(
			host: makeHost(), ancestors: [makeHost()],
			configSink: sink,
			askpassPath: "/tmp/a", knownHostsCaterm: "/tmp/k1", knownHostsUser: "/tmp/k2"
		)
		let cfg = sink.writes.last?.1 ?? ""
		XCTAssertFalse(cfg.contains("ExitOnForwardFailure"))
		XCTAssertFalse(cfg.contains("LocalForward"))
	}
}
