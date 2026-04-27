import XCTest
@testable import KeychainStore
@testable import SessionStore
@testable import SSHCommandBuilder

/// End-to-end integration test that exercises the SSHCommandBuilder + askpass +
/// Keychain pipeline against a Docker linuxserver/openssh-server container.
///
/// SKIPPED unless env CATERM_E2E_DOCKER=1 is set — this test:
/// - Requires Docker daemon running with caterm-smoke container on port 2222
/// - Requires the .build/debug/caterm-askpass binary to be signed
/// - Stuffs a real Keychain item in login keychain (cleans up in tearDown)
@MainActor
final class EndToEndSSHTests: XCTestCase {
    let dockerHostId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var keychain: KeychainStore!
    var askpassPath: String!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["CATERM_E2E_DOCKER"] == "1" else {
            throw XCTSkip("Set CATERM_E2E_DOCKER=1 + run Docker container to enable")
        }
        let cwd = FileManager.default.currentDirectoryPath
        askpassPath = "\(cwd)/.build/debug/caterm-askpass"
        XCTAssertTrue(FileManager.default.fileExists(atPath: askpassPath),
                      "askpass binary missing — run swift build first")

        // Seed the Keychain item via the SAME signed askpass binary that will
        // later read it. Writing through the askpass binary puts its
        // signing identity into the item's partition list automatically, so
        // the read does not trigger an "Always Allow" dialog. Without this
        // bootstrap, the binary that wrote (xctest, Apple-signed) and the
        // binary that reads (caterm-askpass, dev-signed) have different
        // partition entries and macOS prompts.
        try stuffViaAskpass(secret: "spikepass")
        keychain = KeychainStore(service: "com.caterm.host", accessGroup: nil)
    }

    override func tearDownWithError() throws {
        try? keychain?.delete(account: "\(dockerHostId.uuidString).password")
    }

    /// Runs caterm-askpass in CATERM_ASKPASS_STUFF=1 mode to populate the
    /// Keychain item so the partition list includes the binary's signing
    /// identity (avoiding the per-session ACL dialog).
    private func stuffViaAskpass(secret: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: askpassPath)
        p.environment = [
            "CATERM_ASKPASS_STUFF": "1",
            "CATERM_HOST_ID": dockerHostId.uuidString,
            "CATERM_ASKPASS_KIND": "password",
            "CATERM_ASKPASS_SECRET": secret,
        ]
        let stderr = Pipe()
        p.standardError = stderr
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            XCTFail("Askpass stuff mode failed (\(p.terminationStatus)): \(err)")
        }
    }

    func testBuildersWireToWorkingSSHConnection() throws {
        // askpassPath was resolved + verified in setUp.
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Caterm", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir,
                                                withIntermediateDirectories: true)
        let knownCaterm = supportDir.appendingPathComponent("known_hosts").path
        let knownUser = ("~/.ssh/known_hosts" as NSString).expandingTildeInPath

        let host = SSHHost(
            id: dockerHostId, name: "docker-smoke",
            hostname: "127.0.0.1", port: 2222, username: "spike",
            credential: .password
        )

        let built = SSHCommandBuilder.build(
            host: host, askpassPath: askpassPath,
            knownHostsCaterm: knownCaterm, knownHostsUser: knownUser
        )

        // We append a remote command + redirect stdin to /dev/null so the test
        // runs to completion non-interactively. The interactive `exit` flow
        // from a real terminal is exercised by the SwiftUI smoke harness; here
        // we just need to prove auth + connect + clean exit work end-to-end.
        //
        // SSH under Process() with stdin connected to a Pipe (no data) hangs
        // during authentication on macOS — bypass by redirecting stdin to
        // /dev/null at the bash level. This still mirrors what libghostty
        // does (it allocates a PTY which detaches from any parent tty too).
        let remoteSentinel = "CATERM_E2E_REMOTE_OK"
        let cmd = "\(built.command) 'echo \(remoteSentinel); exit 0' < /dev/null"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", cmd]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in built.env { env[k] = v }
        process.environment = env

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe // merge

        try process.run()

        // Bound the wall-clock so a failure doesn't hang the test forever.
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 20)
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: data, encoding: .utf8) ?? "<undecodable>"
        print("===== ssh output =====\n\(outStr)\n=====")

        XCTAssertEqual(process.terminationStatus, 0,
                       "ssh exited non-zero. Output:\n\(outStr)")
        XCTAssertTrue(outStr.contains(remoteSentinel),
                      "Expected remote sentinel \(remoteSentinel). Got:\n\(outStr)")

        // FailureKind.cleanExit semantics: child exited 0 with hadConnected.
        // Verify SessionStore would record this transition.
        let tmpHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-e2e-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmpHostsURL) }
        let store = SessionStore(askpassPath: askpassPath,
                                 knownHostsCaterm: knownCaterm,
                                 knownHostsUser: knownUser,
                                 accessGroup: nil,
                                 hostsURL: tmpHostsURL,
                                 keychain: keychain)
        let tabId = store.openTab(host: host)
        store.markConnecting(tabId: tabId)
        store.markConnected(tabId: tabId)
        store.markChildExited(tabId: tabId, exitCode: 0)
        let tab = store.tabs.first { $0.id == tabId }
        XCTAssertEqual(tab?.state, .failed(.cleanExit))
    }
}
