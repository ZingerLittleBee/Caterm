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
}
