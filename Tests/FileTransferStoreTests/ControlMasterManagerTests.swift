import XCTest
@testable import FileTransferStore

@MainActor
final class ControlMasterManagerTests: XCTestCase {
    func testSocketPathIsHostScoped() {
        let mgr = ControlMasterManager(cacheDir: URL(fileURLWithPath: "/tmp/cm"))
        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let p = mgr.socketPath(for: id)
		XCTAssertEqual(p.path, "/tmp/cm/MzMzMzMzMzMzMzMzMzMzMw.sock")
		XCTAssertLessThanOrEqual(
			p.lastPathComponent.utf8.count
				+ CacheDirectories.openSSHTemporarySuffixBytes,
			CacheDirectories.unixSocketPathMaxBytes
		)
    }

    func testIsAliveCallsSshCheckWithDestination() async {
        let recorder = FakeProcessRunner()
        let mgr = ControlMasterManager(
            cacheDir: URL(fileURLWithPath: "/tmp/cm"),
            runner: recorder
        )
        let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        mgr.register(hostId: id, destination: "alice@h.example")
        recorder.nextExitCode = 0
        let alive = await mgr.isAlive(hostId: id)
        XCTAssertTrue(alive)
        XCTAssertEqual(recorder.lastArgv, [
            "/usr/bin/ssh",
            "-S", "RERERERERERERERERERERA.sock",
            "-O", "check",
            "alice@h.example",
        ])
		XCTAssertEqual(recorder.lastWorkingDirectory, URL(fileURLWithPath: "/tmp/cm"))
    }

    func testIsAliveReturnsFalseOnNonZeroExit() async {
        let recorder = FakeProcessRunner()
        let mgr = ControlMasterManager(
            cacheDir: URL(fileURLWithPath: "/tmp/cm"),
            runner: recorder
        )
        let id = UUID()
        mgr.register(hostId: id, destination: "x@y")
        recorder.nextExitCode = 255
        let alive = await mgr.isAlive(hostId: id)
        XCTAssertFalse(alive)
    }

    func testIsAliveReturnsFalseWhenDestinationMissing() async {
        let mgr = ControlMasterManager(cacheDir: URL(fileURLWithPath: "/tmp/cm"))
        let alive = await mgr.isAlive(hostId: UUID())
        XCTAssertFalse(alive)
    }

	func testTearDownUsesRelativeSocketFromCacheDirectory() async {
		let recorder = FakeProcessRunner()
		let directory = URL(fileURLWithPath: "/tmp/cm")
		let manager = ControlMasterManager(cacheDir: directory, runner: recorder)
		let id = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
		manager.register(hostId: id, destination: "caterm@example.test")

		await manager.tearDown(hostId: id)

		XCTAssertEqual(recorder.lastArgv, [
			"/usr/bin/ssh",
			"-S", "VVVVVVVVRVWFVVVVVVVVVQ.sock",
			"-O", "exit",
			"caterm@example.test",
		])
		XCTAssertEqual(recorder.lastWorkingDirectory, directory)
	}
}

/// Test-only stub.
final class FakeProcessRunner: ProcessRunner, @unchecked Sendable {
    var nextExitCode: Int32 = 0
    var lastArgv: [String] = []
	var lastWorkingDirectory: URL?
    func run(
		argv: [String],
		env: [String: String],
		workingDirectory: URL
	) async -> Int32 {
        lastArgv = argv
		lastWorkingDirectory = workingDirectory
        return nextExitCode
    }
}
