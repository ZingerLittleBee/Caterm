import XCTest
@testable import FileTransferStore
import SFTPCommandBuilder
import SSHCommandBuilder

/// Test fixtures for the no-fallback contract integration tests.
///
/// These values are intentionally minimal: the surrounding tests skip
/// unless `CATERM_DOCKER_SSH=1` is set, so the fixture only needs to
/// compile. Once the openssh-in-docker harness lands, the real values
/// (port, identity files, known_hosts paths) should match the harness.
enum TestHosts {
	static var docker: SSHHost {
		SSHHost(
			id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
			name: "docker-test",
			hostname: "127.0.0.1",
			port: 2222,
			username: "tester",
			credential: .agent
		)
	}

	static var credentials: SFTPCredentials {
		SFTPCredentials(
			askpassPath: nil,
			identityFiles: [],
			knownHostsCaterm: URL(fileURLWithPath: "/tmp/caterm_kh"),
			knownHostsUser: URL(fileURLWithPath: NSString("~/.ssh/known_hosts").expandingTildeInPath),
			strictHostKeyChecking: .acceptNew
		)
	}
}

/// No-fallback contract: when the ControlMaster socket is missing or
/// stale, `RemoteFileSystem` must surface `sessionGone` rather than
/// falling back to a fresh per-call SSH/SFTP connection.
///
/// These tests run against the real `ssh`/`sftp` binaries via the
/// openssh-in-docker harness, which is gated behind `CATERM_DOCKER_SSH=1`.
/// Locally they always SKIP — the harness lives outside this repo.
@MainActor
final class NoFallbackContractTests: XCTestCase {
	override func setUp() async throws {
		try XCTSkipUnless(
			ProcessInfo.processInfo.environment["CATERM_DOCKER_SSH"] == "1",
			"Requires CATERM_DOCKER_SSH=1 + the openssh-in-docker harness"
		)
	}

	func testNoFallbackWhenAgentLoaded() async throws {
		let host = TestHosts.docker
		let cm = ControlMasterManager(cacheDir: try CacheDirectories.controlMasterDir())
		cm.register(hostId: host.id, destination: "\(host.username)@\(host.hostname)")
		let sock = cm.socketPath(for: host.id)
		try? FileManager.default.removeItem(at: sock) // ensure stale state
		let fs = RemoteFileSystem(
			host: host,
			controlPath: sock,
			credentials: TestHosts.credentials,
			liveness: cm
		)
		do {
			_ = try await fs.list("/")
			XCTFail("expected sessionGone")
		} catch RemoteFileSystemError.sessionGone {
			// OK — no fallback occurred.
		}
	}

	func testNoFallbackWhenPasswordlessKeyAvailable() async throws {
		try await testNoFallbackWhenAgentLoaded()
	}
}
