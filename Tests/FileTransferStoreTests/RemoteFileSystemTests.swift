import XCTest
@testable import FileTransferStore
import SFTPCommandBuilder
import SSHCommandBuilder

final class RemoteFileSystemTests: XCTestCase {
	final class FakeSFTPRunner: SFTPRunner, @unchecked Sendable {
		var nextStdout: String = ""
		var nextExit: Int32 = 0
		var lastInvocation: SFTPInvocation?
		func run(_ inv: SFTPInvocation) async throws -> (stdout: String, exit: Int32) {
			lastInvocation = inv
			return (nextStdout, nextExit)
		}
	}
	final class AlwaysAlive: ControlMasterLiveness, @unchecked Sendable {
		func isAlive(hostId: UUID) async -> Bool { true }
	}
	final class NeverAlive: ControlMasterLiveness, @unchecked Sendable {
		func isAlive(hostId: UUID) async -> Bool { false }
	}

	func makeHost() -> SSHHost {
		SSHHost(id: UUID(), name: "x", hostname: "h", port: 22, username: "u", credential: .agent)
	}
	func makeCreds() -> SFTPCredentials {
		SFTPCredentials(askpassPath: nil, identityFiles: [],
		                knownHostsCaterm: URL(fileURLWithPath: "/k1"),
		                knownHostsUser: URL(fileURLWithPath: "/k2"),
		                strictHostKeyChecking: .acceptNew)
	}

	func testListThrowsWhenSessionGone() async {
		let fs = RemoteFileSystem(host: makeHost(),
		                          controlPath: URL(fileURLWithPath: "/sock"),
		                          credentials: makeCreds(),
		                          runner: FakeSFTPRunner(),
		                          liveness: NeverAlive())
		do {
			_ = try await fs.list("/")
			XCTFail("expected throw")
		} catch RemoteFileSystemError.sessionGone {
			// expected
		} catch {
			XCTFail("got \(error)")
		}
	}

	func testListParsesLsLaOutput() async throws {
		let runner = FakeSFTPRunner()
		runner.nextStdout = """
		sftp> cd "/etc"
		sftp> ls -la
		drwxr-xr-x  10 root  wheel   320 Apr 30 10:00 .
		drwxr-xr-x  20 root  wheel   640 Apr  1 12:00 ..
		-rw-r--r--   1 root  wheel  1234 Apr 30 09:00 hosts
		sftp> exit
		"""
		let fs = RemoteFileSystem(host: makeHost(),
		                          controlPath: URL(fileURLWithPath: "/sock"),
		                          credentials: makeCreds(),
		                          runner: runner,
		                          liveness: AlwaysAlive())
		let entries = try await fs.list("/etc")
		XCTAssertEqual(entries.count, 1)
		XCTAssertEqual(entries[0].name, "hosts")
		XCTAssertFalse(entries[0].isDirectory)
		XCTAssertEqual(entries[0].size, 1234)
	}

	func testMkdirInvokesSubprocessAndPropagatesFailure() async {
		let runner = FakeSFTPRunner()
		runner.nextStdout = "permission denied\n"
		runner.nextExit = 1
		let fs = RemoteFileSystem(host: makeHost(),
		                          controlPath: URL(fileURLWithPath: "/sock"),
		                          credentials: makeCreds(),
		                          runner: runner,
		                          liveness: AlwaysAlive())
		do {
			try await fs.mkdir("/srv/new")
			XCTFail()
		} catch let RemoteFileSystemError.subprocessFailed(code, _) {
			XCTAssertEqual(code, 1)
		} catch {
			XCTFail("got \(error)")
		}
	}
}
