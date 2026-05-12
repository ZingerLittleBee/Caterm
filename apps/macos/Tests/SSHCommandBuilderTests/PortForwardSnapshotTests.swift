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
