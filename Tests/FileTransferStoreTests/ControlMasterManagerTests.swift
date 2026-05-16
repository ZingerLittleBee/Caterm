import XCTest
@testable import FileTransferStore

@MainActor
final class ControlMasterManagerTests: XCTestCase {
    func testSocketPathIsHostScoped() {
        let mgr = ControlMasterManager(cacheDir: URL(fileURLWithPath: "/tmp/cm"))
        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let p = mgr.socketPath(for: id)
        XCTAssertEqual(p.path, "/tmp/cm/33333333-3333-3333-3333-333333333333.sock")
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
            "-S", "/tmp/cm/44444444-4444-4444-4444-444444444444.sock",
            "-O", "check",
            "alice@h.example",
        ])
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
}

/// Test-only stub.
final class FakeProcessRunner: ProcessRunner, @unchecked Sendable {
    var nextExitCode: Int32 = 0
    var lastArgv: [String] = []
    func run(argv: [String], env: [String: String]) async -> Int32 {
        lastArgv = argv
        return nextExitCode
    }
}
