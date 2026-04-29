import XCTest
@testable import SSHCommandBuilder

final class TerminfoInstallTests: XCTestCase {

    private func sampleHost() -> SSHHost {
        SSHHost(
            name: "test-host",
            hostname: "example.com",
            port: 22,
            username: "alice",
            credential: .agent
        )
    }

    private static let askpassPath = "/tmp/caterm-askpass-stub"
    private static let knownHostsCaterm = "/tmp/caterm-known-hosts"
    private static let knownHostsUser = "/tmp/user-known-hosts"

    /// Regression guard: the v1.5 baseline shape must be byte-for-byte preserved
    /// when `installTerminfo: false` (the default).
    func testInstallTerminfoFalseMatchesV15Baseline() {
        let baseline = SSHCommandBuilder.build(
            host: sampleHost(),
            askpassPath: Self.askpassPath,
            knownHostsCaterm: Self.knownHostsCaterm,
            knownHostsUser: Self.knownHostsUser
        )
        let withFalse = SSHCommandBuilder.build(
            host: sampleHost(),
            askpassPath: Self.askpassPath,
            knownHostsCaterm: Self.knownHostsCaterm,
            knownHostsUser: Self.knownHostsUser,
            installTerminfo: false
        )
        XCTAssertEqual(baseline.command, withFalse.command)
        XCTAssertEqual(baseline.env.map { $0.0 }, withFalse.env.map { $0.0 })
        XCTAssertEqual(baseline.env.map { $0.1 }, withFalse.env.map { $0.1 })
        // And: no -t flag, no TERM override.
        XCTAssertFalse(withFalse.command.contains(" -t "))
        XCTAssertFalse(withFalse.env.contains(where: { $0.0 == "TERM" }))
    }

    /// `installTerminfo: true` adds a `-t` flag, appends a quoted remote
    /// command containing the wrapper, and adds `TERM=xterm-ghostty` to env.
    func testInstallTerminfoTrueAppendsWrapperAndEnv() {
        let out = SSHCommandBuilder.build(
            host: sampleHost(),
            askpassPath: Self.askpassPath,
            knownHostsCaterm: Self.knownHostsCaterm,
            knownHostsUser: Self.knownHostsUser,
            installTerminfo: true
        )
        XCTAssertTrue(out.command.contains(" -t "), "expected -t flag in: \(out.command)")
        XCTAssertTrue(out.command.contains("infocmp xterm-ghostty"), "wrapper missing infocmp probe")
        XCTAssertTrue(out.command.contains("tic -x -"), "wrapper missing tic invocation")
        // The wrapper is wrapped in POSIX single-quotes by `ShellQuote.posix`,
        // which escapes the embedded single quotes around the heredoc tag as
        // `'\''…'\''`. The runtime form (after the local shell strips its
        // outer quoting) reconstitutes `<<'TERMINFO_EOF'`.
        XCTAssertTrue(
            out.command.contains("<<'\\''TERMINFO_EOF'\\''")
                || out.command.contains("<<'TERMINFO_EOF'"),
            "wrapper missing single-quoted heredoc delimiter; got: \(out.command)"
        )
        XCTAssertTrue(out.command.contains("xterm-ghostty|"), "wrapper missing terminfo dump body")
        XCTAssertTrue(out.command.contains("exec \"${SHELL:-/bin/sh}\" -l"), "wrapper missing exec line")
        XCTAssertTrue(
            out.env.contains(where: { $0.0 == "TERM" && $0.1 == "xterm-ghostty" }),
            "expected TERM=xterm-ghostty in env, got: \(out.env)"
        )
    }

    /// When the bundle resource is missing (build/packaging error caught by
    /// the CI gate `TerminfoSourceTests` but defended at runtime too), the
    /// builder degrades to the `installTerminfo: false` shape — never
    /// advertise xterm-ghostty without a backing terminfo install.
    func testBundleMissingFallbackEqualsToggleOff() {
        let toggleOff = SSHCommandBuilder._build(
            host: sampleHost(),
            askpassPath: Self.askpassPath,
            knownHostsCaterm: Self.knownHostsCaterm,
            knownHostsUser: Self.knownHostsUser,
            installTerminfo: false,
            sshPath: "/usr/bin/ssh",
            terminfoDump: nil
        )
        let bundleMissing = SSHCommandBuilder._build(
            host: sampleHost(),
            askpassPath: Self.askpassPath,
            knownHostsCaterm: Self.knownHostsCaterm,
            knownHostsUser: Self.knownHostsUser,
            installTerminfo: true,           // toggle ON
            sshPath: "/usr/bin/ssh",
            terminfoDump: nil                // ...but bundle missing
        )
        XCTAssertEqual(toggleOff, bundleMissing,
            "bundle-missing must produce identical Output to toggle-off — no -t, no TERM env override")
        XCTAssertFalse(bundleMissing.command.contains(" -t "))
        XCTAssertFalse(bundleMissing.env.contains(where: { $0.0 == "TERM" }))
    }

    /// End-to-end: hand the assembled command to a real `/bin/sh -c`,
    /// configure `sshPath:` to point at a stub script that NUL-dumps its argv,
    /// and assert the inner `ssh` argv contains the expected pieces. This
    /// validates `ShellQuote.posix` survives a 3-KB heredoc-containing
    /// wrapper through real shell parsing — not just internal round-trip.
    func testEndToEndArgvThroughBinSh() throws {
        // 1. Create the temp stub directory and the stub script.
        let tmpDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let argvDump = tmpDir.appendingPathComponent("argv.dump").path
        let stubURL = tmpDir.appendingPathComponent("ssh-stub.sh")

        // `printf '%s\0' "$0" "$@"` — `$0` is the script path, `$@` is argv[1..].
        // Without `$0` the argv[0] entry would silently be missing. NUL
        // separation is required because the wrapper itself contains newlines.
        let stubBody = """
        #!/bin/sh
        printf '%s\\0' "$0" "$@" > "\(argvDump)"
        """
        try stubBody.write(to: stubURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: stubURL.path
        )

        // 2. Build the command pointing at the stub instead of /usr/bin/ssh.
        guard let dump = TerminfoSource.terminfoDump() else {
            XCTFail("bundled dump is nil — TerminfoSourceTests should have caught this earlier")
            return
        }
        let out = SSHCommandBuilder._build(
            host: sampleHost(),
            askpassPath: Self.askpassPath,
            knownHostsCaterm: Self.knownHostsCaterm,
            knownHostsUser: Self.knownHostsUser,
            installTerminfo: true,
            sshPath: stubURL.path,
            terminfoDump: dump
        )

        // 3. Run the assembled command via real /bin/sh -c.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", out.command]
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        try proc.run()
        proc.waitUntilExit()
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(proc.terminationStatus, 0, "shell rejected the command. stderr: \(stderr)")

        // 4. Read the argv dump and split on NUL. `printf '%s\0' a b c` emits
        // `a\0b\0c\0` (a trailing NUL after each entry, including the last),
        // so splitting non-empty drops the trailing empty token cleanly.
        let dumpData = try Data(contentsOf: URL(fileURLWithPath: argvDump))
        let argv = String(data: dumpData, encoding: .utf8)?
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init) ?? []

        // 5. Assertions.
        XCTAssertGreaterThan(argv.count, 5, "expected substantial argv, got: \(argv)")
        XCTAssertEqual(argv.first, stubURL.path, "argv[0] should be the stub script path")
        XCTAssertTrue(argv.contains("-t"), "expected -t flag among argv: \(argv)")

        // The wrapper must arrive as a single argv entry (the heredoc body
        // and embedded newlines must NOT have been split by the outer shell).
        let wrapperCandidate = argv.last
        XCTAssertNotNil(wrapperCandidate)
        XCTAssertTrue(wrapperCandidate?.contains("infocmp xterm-ghostty") ?? false,
                      "last argv entry should be the wrapper containing infocmp probe")
        XCTAssertTrue(wrapperCandidate?.contains("xterm-ghostty|") ?? false,
                      "wrapper must contain terminfo dump body")
        XCTAssertTrue(wrapperCandidate?.contains("exec \"${SHELL:-/bin/sh}\" -l") ?? false,
                      "wrapper must contain exec line")
    }
}
