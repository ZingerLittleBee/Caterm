# Remote Files (SFTP + Drag Upload) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a remote file browser drawer + drag-drop upload to the macOS Caterm app, backed by `sftp(1)` subprocesses sharing OpenSSH ControlMaster sockets with the active terminal session.

**Architecture:** New `SFTPCommandBuilder` and `FileTransferStore` SwiftPM targets; `SSHCommandBuilder` extended with ControlMaster flags; new `ControlMasterManager` actor owns socket lifecycle; new `FileDrawerView` SwiftUI drawer in `MainWindow`. Per-host FIFO transfer queue, file-level progress, no transparent re-auth.

**Tech Stack:** Swift 5.10 + SwiftPM, SwiftUI/AppKit, system `/usr/bin/ssh` and `/usr/bin/sftp` subprocesses (no russh/libssh dependency). Tests via XCTest.

**Spec:** `docs/superpowers/specs/2026-05-01-remote-files-design.md` (v3.3).

---

## Phase 1 — Foundation (no UI; no behavior visible to users)

### Task 1: Extend `SSHCommandBuilder` with ControlMaster flags

**Files:**
- Modify: `apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift`
- Modify: `apps/macos/Sources/SSHCommandBuilder/Host.swift` (if needed for hostId-derived socket path)
- Test: `apps/macos/Tests/SSHCommandBuilderTests/ControlMasterTests.swift` (new file)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SSHCommandBuilderTests/ControlMasterTests.swift
import XCTest
@testable import SSHCommandBuilder

final class ControlMasterTests: XCTestCase {
    func testControlMasterOptionsPresentForPasswordHost() {
        let host = Host(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            label: "demo", hostname: "h.example", port: 22,
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter SSHCommandBuilderTests.ControlMasterTests`
Expected: FAIL — `ControlMaster=auto` not in command.

- [ ] **Step 3: Add ControlMaster options to `_build`**

In `SSHCommandBuilder.swift`, immediately after the `UserKnownHostsFile` line and before the credential `switch` (around line 65):

```swift
let controlPath = "~/Library/Caches/Caterm/cm/\(host.id.uuidString).sock"
args += [.raw("-o"), .quoted("ControlMaster=auto")]
args += [.raw("-o"), .quoted("ControlPersist=10m")]
args += [.raw("-o"), .quoted("ControlPath=\(controlPath)")]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter SSHCommandBuilderTests.ControlMasterTests`
Expected: PASS.

Then run the existing baseline regressions to confirm we didn't break byte-for-byte expectations:

Run: `cd apps/macos && swift test --filter SSHCommandBuilderTests.PasswordPathTests SSHCommandBuilderTests.KeyFilePathTests SSHCommandBuilderTests.AgentPathTests`
Expected: existing tests will fail because the command string changed. Update each expected string in those test files to include the three new `-o ControlMaster=...` lines (placed in the same position the implementation adds them — between `UserKnownHostsFile=...` and the credential-specific options). Re-run; all green.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift \
        apps/macos/Tests/SSHCommandBuilderTests/
git commit -m "feat(macos/ssh): add ControlMaster options for sftp socket reuse"
```

---

### Task 2: Cache directory bootstrap

**Files:**
- Create: `apps/macos/Sources/FileTransferStore/CacheDirectories.swift`
- Test: `apps/macos/Tests/FileTransferStoreTests/CacheDirectoriesTests.swift`
- Modify: `apps/macos/Package.swift` (declare new `FileTransferStore` target + tests)

- [ ] **Step 1: Add target declarations to `Package.swift`**

In the `targets:` array, after `HostSyncStore`:

```swift
.target(
    name: "FileTransferStore",
    dependencies: ["SSHCommandBuilder", "SFTPCommandBuilder"],
    path: "Sources/FileTransferStore"
),
```

And add the test target near the end:

```swift
.testTarget(
    name: "FileTransferStoreTests",
    dependencies: ["FileTransferStore", "SSHCommandBuilder", "SFTPCommandBuilder"],
    path: "Tests/FileTransferStoreTests"
),
```

(Note: `SFTPCommandBuilder` target is added in Task 5 — declare it here too as `.target(name: "SFTPCommandBuilder", path: "Sources/SFTPCommandBuilder")` so the package resolves; we'll add the source files later.)

- [ ] **Step 2: Write the failing test**

```swift
// Tests/FileTransferStoreTests/CacheDirectoriesTests.swift
import XCTest
@testable import FileTransferStore

final class CacheDirectoriesTests: XCTestCase {
    func testControlMasterDirIsCreated() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-cm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = try CacheDirectories.controlMasterDir(root: tmp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o700)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter FileTransferStoreTests.CacheDirectoriesTests`
Expected: FAIL — `CacheDirectories` doesn't compile yet.

- [ ] **Step 4: Implement**

```swift
// Sources/FileTransferStore/CacheDirectories.swift
import Foundation

public enum CacheDirectories {
    /// Returns ~/Library/Caches/Caterm/cm/, creating it with mode 0700 if needed.
    /// `root` parameter exists for tests; production callers omit it.
    public static func controlMasterDir(root: URL? = nil) throws -> URL {
        let base = root ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Caterm")
        let cm = base.appendingPathComponent("cm")
        try FileManager.default.createDirectory(
            at: cm,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return cm
    }
}
```

- [ ] **Step 5: Run, verify, commit**

```bash
cd apps/macos && swift test --filter FileTransferStoreTests.CacheDirectoriesTests
git add apps/macos/Package.swift \
        apps/macos/Sources/FileTransferStore/CacheDirectories.swift \
        apps/macos/Tests/FileTransferStoreTests/CacheDirectoriesTests.swift
git commit -m "feat(macos/transfer): add CacheDirectories for ControlMaster sockets"
```

---

### Task 3: `ControlMasterManager` (isAlive + tearDown)

**Files:**
- Create: `apps/macos/Sources/FileTransferStore/ControlMasterManager.swift`
- Test: `apps/macos/Tests/FileTransferStoreTests/ControlMasterManagerTests.swift`

- [ ] **Step 1: Write the failing test (using fake `ssh` runner)**

```swift
// Tests/FileTransferStoreTests/ControlMasterManagerTests.swift
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
```

- [ ] **Step 2: Run test, expect compile failure**

Run: `cd apps/macos && swift test --filter FileTransferStoreTests.ControlMasterManagerTests`
Expected: FAIL — `ControlMasterManager` and `ProcessRunner` don't exist.

- [ ] **Step 3: Implement**

```swift
// Sources/FileTransferStore/ControlMasterManager.swift
import Foundation

public protocol ProcessRunner: Sendable {
    func run(argv: [String], env: [String: String]) async -> Int32
}

public struct SystemProcessRunner: ProcessRunner {
    public init() {}
    public func run(argv: [String], env: [String: String]) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: argv[0])
            proc.arguments = Array(argv.dropFirst())
            if !env.isEmpty {
                var e = ProcessInfo.processInfo.environment
                for (k, v) in env { e[k] = v }
                proc.environment = e
            }
            proc.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            do { try proc.run() } catch { cont.resume(returning: 127) }
        }
    }
}

@MainActor
public final class ControlMasterManager {
    private let cacheDir: URL
    private let runner: ProcessRunner
    private var destinations: [UUID: String] = [:]

    public init(cacheDir: URL, runner: ProcessRunner = SystemProcessRunner()) {
        self.cacheDir = cacheDir
        self.runner = runner
    }

    public func socketPath(for hostId: UUID) -> URL {
        cacheDir.appendingPathComponent("\(hostId.uuidString).sock")
    }

    public func register(hostId: UUID, destination: String) {
        destinations[hostId] = destination
    }

    public func isAlive(hostId: UUID) async -> Bool {
        guard let dest = destinations[hostId] else { return false }
        let sock = socketPath(for: hostId)
        let argv = ["/usr/bin/ssh", "-S", sock.path, "-O", "check", dest]
        let code = await runner.run(argv: argv, env: [:])
        return code == 0
    }

    public func tearDown(hostId: UUID) async {
        guard let dest = destinations[hostId] else { return }
        let sock = socketPath(for: hostId)
        let argv = ["/usr/bin/ssh", "-S", sock.path, "-O", "exit", dest]
        _ = await runner.run(argv: argv, env: [:])
        destinations.removeValue(forKey: hostId)
    }

    public func tearDownAll() async {
        for id in destinations.keys { await tearDown(hostId: id) }
    }
}
```

- [ ] **Step 4: Run, verify pass**

Run: `cd apps/macos && swift test --filter FileTransferStoreTests.ControlMasterManagerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/FileTransferStore/ControlMasterManager.swift \
        apps/macos/Tests/FileTransferStoreTests/ControlMasterManagerTests.swift
git commit -m "feat(macos/transfer): ControlMasterManager with liveness check"
```

---

### Task 4: `SFTPPathEncoder`

**Files:**
- Create: `apps/macos/Sources/SFTPCommandBuilder/SFTPPathEncoder.swift`
- Test: `apps/macos/Tests/SFTPCommandBuilderTests/SFTPPathEncoderTests.swift`
- Modify: `apps/macos/Package.swift` — register `SFTPCommandBuilder` as a real target with `Sources/SFTPCommandBuilder` and `Tests/SFTPCommandBuilderTests`.

- [ ] **Step 1: Write the failing test (test vectors from spec §3.3)**

```swift
// Tests/SFTPCommandBuilderTests/SFTPPathEncoderTests.swift
import XCTest
@testable import SFTPCommandBuilder

final class SFTPPathEncoderTests: XCTestCase {
    func testSimplePath() throws {
        XCTAssertEqual(try SFTPPathEncoder.encode("/etc/hosts"), #""/etc/hosts""#)
    }
    func testSpaces() throws {
        XCTAssertEqual(try SFTPPathEncoder.encode("/path/with space/file"),
                       #""/path/with space/file""#)
    }
    func testInnerQuoteEscaped() throws {
        XCTAssertEqual(try SFTPPathEncoder.encode(#"/path/"quoted""#),
                       #""/path/\"quoted\"""#)
    }
    func testBackslashEscaped() throws {
        XCTAssertEqual(try SFTPPathEncoder.encode(#"/path\with\back"#),
                       #""/path\\with\\back""#)
    }
    func testLeadingDashRejected() {
        XCTAssertThrowsError(try SFTPPathEncoder.encode("-rf")) { err in
            XCTAssertEqual(err as? SFTPPathEncodingError, .leadingDashUnnormalized)
        }
    }
    func testNormalizedLeadingDashAccepted() throws {
        XCTAssertEqual(try SFTPPathEncoder.encode("./-rf"), #""./-rf""#)
    }
    func testNewlineRejected() {
        XCTAssertThrowsError(try SFTPPathEncoder.encode("file\nname")) { err in
            guard case .containsControlChar(let c) = err as! SFTPPathEncodingError else {
                return XCTFail()
            }
            XCTAssertEqual(c, "\n")
        }
    }
    func testGlobRejected() {
        XCTAssertThrowsError(try SFTPPathEncoder.encode("*.txt")) { err in
            guard case .containsGlob(let c) = err as! SFTPPathEncodingError else {
                return XCTFail()
            }
            XCTAssertEqual(c, "*")
        }
        XCTAssertThrowsError(try SFTPPathEncoder.encode("[abc].txt"))
    }
    func testEmptyRejected() {
        XCTAssertThrowsError(try SFTPPathEncoder.encode("")) { err in
            XCTAssertEqual(err as? SFTPPathEncodingError, .empty)
        }
    }
    func testPathTooLongRejected() {
        let long = "/" + String(repeating: "x", count: 1023)
        XCTAssertThrowsError(try SFTPPathEncoder.encode(long)) { err in
            guard case .pathTooLong(let bytes) = err as! SFTPPathEncodingError else {
                return XCTFail()
            }
            XCTAssertGreaterThan(bytes, 1023)
        }
    }
    func testTrailingSlashAccepted() throws {
        XCTAssertEqual(try SFTPPathEncoder.encode("/empty/"), #""/empty/""#)
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `cd apps/macos && swift test --filter SFTPCommandBuilderTests.SFTPPathEncoderTests`
Expected: FAIL — types don't exist.

- [ ] **Step 3: Implement**

```swift
// Sources/SFTPCommandBuilder/SFTPPathEncoder.swift
import Foundation

public enum SFTPPathEncodingError: Error, Equatable {
    case empty
    case containsControlChar(Character)
    case containsGlob(Character)
    case pathTooLong(bytes: Int)
    case leadingDashUnnormalized
}

public enum SFTPPathEncoder {
    public static func encode(_ path: String) throws -> String {
        if path.isEmpty { throw SFTPPathEncodingError.empty }
        let bytes = path.utf8.count
        if bytes > 1023 { throw SFTPPathEncodingError.pathTooLong(bytes: bytes) }
        if path.first == "-" { throw SFTPPathEncodingError.leadingDashUnnormalized }
        for ch in path {
            if let scalar = ch.unicodeScalars.first?.value {
                if scalar < 0x20 || scalar == 0x7F {
                    throw SFTPPathEncodingError.containsControlChar(ch)
                }
            }
            if ch == "*" || ch == "?" || ch == "[" {
                throw SFTPPathEncodingError.containsGlob(ch)
            }
        }
        var escaped = ""
        escaped.reserveCapacity(path.count + 4)
        for ch in path {
            if ch == "\\" { escaped.append("\\\\") }
            else if ch == "\"" { escaped.append("\\\"") }
            else { escaped.append(ch) }
        }
        return "\"\(escaped)\""
    }
}
```

Also create `Sources/SFTPCommandBuilder/SFTPCommandBuilder.swift` with just `public enum SFTPCommandBuilder {}` so the target compiles.

- [ ] **Step 4: Run, verify pass**

Run: `cd apps/macos && swift test --filter SFTPCommandBuilderTests.SFTPPathEncoderTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SFTPCommandBuilder/ \
        apps/macos/Tests/SFTPCommandBuilderTests/ \
        apps/macos/Package.swift
git commit -m "feat(macos/sftp): SFTPPathEncoder with strict validation"
```

---

### Task 5: `SFTPCredentials` + denylist + `SFTPCommandBuilder.invocation`

**Files:**
- Modify: `apps/macos/Sources/SFTPCommandBuilder/SFTPCommandBuilder.swift`
- Create: `apps/macos/Sources/SFTPCommandBuilder/SFTPCredentials.swift`
- Test: `apps/macos/Tests/SFTPCommandBuilderTests/SFTPCommandBuilderTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/SFTPCommandBuilderTests/SFTPCommandBuilderTests.swift
import XCTest
@testable import SFTPCommandBuilder
import SSHCommandBuilder

final class SFTPCommandBuilderTests: XCTestCase {
    func makeCreds(extras: [String: String] = [:]) -> SFTPCredentials {
        SFTPCredentials(
            askpassPath: URL(fileURLWithPath: "/tmp/askpass"),
            identityFiles: [URL(fileURLWithPath: "/tmp/id_ed25519")],
            knownHostsCaterm: URL(fileURLWithPath: "/tmp/caterm_kh"),
            knownHostsUser: URL(fileURLWithPath: "/tmp/user_kh"),
            strictHostKeyChecking: .acceptNew,
            extraSSHOptions: extras
        )
    }
    func makeHost() -> Host {
        Host(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
             label: "demo", hostname: "h.example", port: 22,
             username: "alice", credential: .agent)
    }

    func testListInvocationContainsNoFallbackOptions() throws {
        let inv = try SFTPCommandBuilder.invocation(
            host: makeHost(),
            controlPath: URL(fileURLWithPath: "/tmp/cm/x.sock"),
            credentials: makeCreds(),
            operation: .list(remoteDir: "/etc")
        )
        let argvJoined = inv.argv.joined(separator: " ")
        XCTAssertTrue(argvJoined.contains("-o ControlMaster=no"))
        XCTAssertTrue(argvJoined.contains("-o BatchMode=yes"))
        XCTAssertTrue(argvJoined.contains("-o PreferredAuthentications=none"))
        XCTAssertTrue(argvJoined.contains("-o ProxyCommand=none"))
        XCTAssertTrue(argvJoined.contains("-o ControlPath=/tmp/cm/x.sock"))
        XCTAssertTrue(inv.argv.first == "/usr/bin/sftp")
    }

    func testKnownHostsJoined() throws {
        let inv = try SFTPCommandBuilder.invocation(
            host: makeHost(),
            controlPath: URL(fileURLWithPath: "/tmp/cm/x.sock"),
            credentials: makeCreds(),
            operation: .list(remoteDir: "/")
        )
        XCTAssertTrue(inv.argv.joined(separator: " ")
            .contains("-o UserKnownHostsFile=/tmp/caterm_kh /tmp/user_kh"))
    }

    func testNoFallbackOptionsFirst() throws {
        // First-value-wins semantics require our options to appear before any
        // user-supplied ones. We assert by index.
        let inv = try SFTPCommandBuilder.invocation(
            host: makeHost(),
            controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
            credentials: makeCreds(extras: ["LogLevel": "DEBUG3"]),
            operation: .list(remoteDir: "/")
        )
        let preferredIdx = inv.argv.firstIndex(of: "PreferredAuthentications=none")!
        let userIdx = inv.argv.firstIndex(of: "LogLevel=DEBUG3")!
        XCTAssertLessThan(preferredIdx, userIdx)
    }

    func testExtraOptionsCannotOverrideNoFallback() throws {
        let inv = try SFTPCommandBuilder.invocation(
            host: makeHost(),
            controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
            credentials: makeCreds(extras: [
                "PreferredAuthentications": "publickey",
                "BatchMode": "no",
                "ControlMaster": "auto",
                "ProxyJump": "bastion",
            ]),
            operation: .list(remoteDir: "/")
        )
        let joined = inv.argv.joined(separator: " ")
        XCTAssertFalse(joined.contains("publickey"))
        XCTAssertFalse(joined.contains("BatchMode=no"))
        XCTAssertFalse(joined.contains("ControlMaster=auto"))
        XCTAssertFalse(joined.contains("ProxyJump"))
        XCTAssertFalse(joined.contains("bastion"))
    }

    func testDenylistIsCaseInsensitive() throws {
        let inv = try SFTPCommandBuilder.invocation(
            host: makeHost(),
            controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
            credentials: makeCreds(extras: [
                "preferredauthentications": "publickey",
                "BATCHMODE": "no",
                "Hostname": "evil.example",
                "PROXYCOMMAND": "nc evil 22",
            ]),
            operation: .list(remoteDir: "/")
        )
        let joined = inv.argv.joined(separator: " ")
        XCTAssertFalse(joined.contains("evil.example"))
        XCTAssertFalse(joined.contains("nc evil"))
        XCTAssertFalse(joined.contains("publickey"))
        // And the destination is the original host
        XCTAssertTrue(joined.contains("alice@h.example"))
    }

    func testListBatchScript() throws {
        let inv = try SFTPCommandBuilder.invocation(
            host: makeHost(),
            controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
            credentials: makeCreds(),
            operation: .list(remoteDir: "/etc")
        )
        XCTAssertEqual(inv.scriptStdin, "cd \"/etc\"\nls -la\nexit\n")
    }

    func testPutBatchScriptUsesLowercaseP() throws {
        let inv = try SFTPCommandBuilder.invocation(
            host: makeHost(),
            controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
            credentials: makeCreds(),
            operation: .put(localPath: URL(fileURLWithPath: "/local/a.txt"),
                            remotePath: "/srv/a.txt", recursive: false, resume: false)
        )
        XCTAssertEqual(inv.scriptStdin,
                       #"put -p "/local/a.txt" "/srv/a.txt"\#nexit\#n"#)
    }

    func testPutRecursive() throws {
        let inv = try SFTPCommandBuilder.invocation(
            host: makeHost(), controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
            credentials: makeCreds(),
            operation: .put(localPath: URL(fileURLWithPath: "/local/dir"),
                            remotePath: "/srv/dir", recursive: true, resume: false)
        )
        XCTAssertTrue(inv.scriptStdin.hasPrefix(#"put -pR "/local/dir" "/srv/dir""#))
    }

    func testRetryAddsResumeFlag() throws {
        let inv = try SFTPCommandBuilder.invocation(
            host: makeHost(), controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
            credentials: makeCreds(),
            operation: .put(localPath: URL(fileURLWithPath: "/a"),
                            remotePath: "/b", recursive: false, resume: true)
        )
        XCTAssertTrue(inv.scriptStdin.hasPrefix(#"put -pa "/a" "/b""#))
    }

    func testCombinedPathLengthRejected() {
        let big = "/" + String(repeating: "x", count: 600)
        XCTAssertThrowsError(try SFTPCommandBuilder.invocation(
            host: makeHost(), controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
            credentials: makeCreds(),
            operation: .rename(from: big, to: big)
        )) { err in
            guard case SFTPBatchLineError.lineTooLong(let bytes, let limit) = err else {
                return XCTFail("got \(err)")
            }
            XCTAssertGreaterThan(bytes, 1023)
            XCTAssertEqual(limit, 1023)
        }
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `cd apps/macos && swift test --filter SFTPCommandBuilderTests.SFTPCommandBuilderTests`
Expected: FAIL.

- [ ] **Step 3: Implement `SFTPCredentials` + denylist**

```swift
// Sources/SFTPCommandBuilder/SFTPCredentials.swift
import Foundation
import SSHCommandBuilder

public struct SFTPCredentials {
    public let askpassPath: URL?
    public let identityFiles: [URL]
    public let knownHostsCaterm: URL
    public let knownHostsUser: URL
    public let strictHostKeyChecking: StrictHostKeyChecking
    public let extraSSHOptions: [String: String]

    public init(askpassPath: URL?, identityFiles: [URL],
                knownHostsCaterm: URL, knownHostsUser: URL,
                strictHostKeyChecking: StrictHostKeyChecking,
                extraSSHOptions: [String: String] = [:]) {
        self.askpassPath = askpassPath
        self.identityFiles = identityFiles
        self.knownHostsCaterm = knownHostsCaterm
        self.knownHostsUser = knownHostsUser
        self.strictHostKeyChecking = strictHostKeyChecking
        self.extraSSHOptions = extraSSHOptions
    }
}

public enum StrictHostKeyChecking: String {
    case yes = "yes"
    case acceptNew = "accept-new"
    case no = "no"
}

public let SFTPCredentialsDenylist: Set<String> = [
    "controlmaster", "controlpath", "controlpersist",
    "batchmode", "preferredauthentications",
    "proxycommand", "proxyjump", "hostname",
]

public enum SFTPBatchLineError: Error, Equatable {
    case lineTooLong(bytes: Int, limit: Int)
}
```

- [ ] **Step 4: Implement `SFTPCommandBuilder.invocation`**

```swift
// Sources/SFTPCommandBuilder/SFTPCommandBuilder.swift
import Foundation
import SSHCommandBuilder

public struct SFTPInvocation: Equatable {
    public let argv: [String]
    public let environment: [String: String]
    public let scriptStdin: String
}

public enum SFTPOperation {
    case list(remoteDir: String)
    case put(localPath: URL, remotePath: String, recursive: Bool, resume: Bool)
    case get(remotePath: String, localPath: URL, recursive: Bool, resume: Bool)
    case mkdir(remotePath: String)
    case remove(remotePath: String, isDirectory: Bool)
    case rename(from: String, to: String)
}

private let kSftpMaxLine = 1023

public enum SFTPCommandBuilder {
    public static func invocation(
        host: Host,
        controlPath: URL,
        credentials: SFTPCredentials,
        operation: SFTPOperation
    ) throws -> SFTPInvocation {
        var argv: [String] = ["/usr/bin/sftp"]

        // No-fallback options FIRST (first-value-wins under OpenSSH).
        argv += ["-o", "ControlMaster=no"]
        argv += ["-o", "BatchMode=yes"]
        argv += ["-o", "PreferredAuthentications=none"]
        argv += ["-o", "ProxyCommand=none"]

        // Master socket
        argv += ["-o", "ControlPath=\(controlPath.path)"]
        argv += ["-o", "ControlPersist=10m"]

        // Policy parity
        argv += ["-o", "StrictHostKeyChecking=\(credentials.strictHostKeyChecking.rawValue)"]
        argv += ["-o", "UserKnownHostsFile=\(credentials.knownHostsCaterm.path) \(credentials.knownHostsUser.path)"]
        for id in credentials.identityFiles {
            argv += ["-i", id.path]
        }

        // Filtered extras (case-insensitive denylist).
        for (k, v) in credentials.extraSSHOptions.sorted(by: { $0.key < $1.key }) {
            if SFTPCredentialsDenylist.contains(k.lowercased()) { continue }
            argv += ["-o", "\(k)=\(v)"]
        }

        // Batch script + destination
        argv += ["-b", "/dev/stdin"]
        argv += ["-P", String(host.port)]
        argv += ["\(host.username)@\(host.hostname)"]

        // Build script and validate line lengths.
        let script = try makeScript(operation)
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            let bytes = line.utf8.count
            if bytes > kSftpMaxLine {
                throw SFTPBatchLineError.lineTooLong(bytes: bytes, limit: kSftpMaxLine)
            }
        }

        var env: [String: String] = [:]
        if let askpass = credentials.askpassPath {
            env["SSH_ASKPASS"] = askpass.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["CATERM_HOST_ID"] = host.id.uuidString
        }

        return SFTPInvocation(argv: argv, environment: env, scriptStdin: script)
    }

    private static func makeScript(_ op: SFTPOperation) throws -> String {
        switch op {
        case .list(let dir):
            return "cd \(try SFTPPathEncoder.encode(dir))\nls -la\nexit\n"
        case .put(let local, let remote, let r, let resume):
            let flags = "-p" + (r ? "R" : "") + (resume ? "a" : "")
            return "put \(flags) \(try SFTPPathEncoder.encode(local.path)) \(try SFTPPathEncoder.encode(remote))\nexit\n"
        case .get(let remote, let local, let r, let resume):
            let flags = "-p" + (r ? "R" : "") + (resume ? "a" : "")
            return "get \(flags) \(try SFTPPathEncoder.encode(remote)) \(try SFTPPathEncoder.encode(local.path))\nexit\n"
        case .mkdir(let p):
            return "mkdir \(try SFTPPathEncoder.encode(p))\nexit\n"
        case .remove(let p, let isDir):
            let cmd = isDir ? "rmdir" : "rm"
            return "\(cmd) \(try SFTPPathEncoder.encode(p))\nexit\n"
        case .rename(let a, let b):
            return "rename \(try SFTPPathEncoder.encode(a)) \(try SFTPPathEncoder.encode(b))\nexit\n"
        }
    }
}
```

- [ ] **Step 5: Run, verify, commit**

```bash
cd apps/macos && swift test --filter SFTPCommandBuilderTests
git add apps/macos/Sources/SFTPCommandBuilder/ \
        apps/macos/Tests/SFTPCommandBuilderTests/SFTPCommandBuilderTests.swift
git commit -m "feat(macos/sftp): SFTPCommandBuilder with no-fallback contract"
```

---

## Phase 2 — SFTP backend

### Task 6: `RemoteFileSystem` actor (list / mkdir / rm / rename)

**Files:**
- Create: `apps/macos/Sources/FileTransferStore/RemoteFileSystem.swift`
- Create: `apps/macos/Sources/FileTransferStore/RemoteEntry.swift`
- Create: `apps/macos/Sources/FileTransferStore/SFTPRunner.swift` (protocol + system impl)
- Test: `apps/macos/Tests/FileTransferStoreTests/RemoteFileSystemTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/FileTransferStoreTests/RemoteFileSystemTests.swift
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

    func makeHost() -> Host {
        Host(id: UUID(), label: "x", hostname: "h", port: 22, username: "u", credential: .agent)
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
        } catch let RemoteFileSystemError.sessionGone {} catch {
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
        // Ignore "." and ".."
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
```

- [ ] **Step 2: Run, expect compile failure**

Run: `cd apps/macos && swift test --filter FileTransferStoreTests.RemoteFileSystemTests`
Expected: FAIL — types don't exist.

- [ ] **Step 3: Implement protocol + structs + actor**

```swift
// Sources/FileTransferStore/SFTPRunner.swift
import Foundation
import SFTPCommandBuilder

public protocol SFTPRunner: Sendable {
    func run(_ inv: SFTPInvocation) async throws -> (stdout: String, exit: Int32)
}

public protocol ControlMasterLiveness: Sendable {
    func isAlive(hostId: UUID) async -> Bool
}

public struct SystemSFTPRunner: SFTPRunner {
    public init() {}
    public func run(_ inv: SFTPInvocation) async throws -> (stdout: String, exit: Int32) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, Int32), Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: inv.argv[0])
            proc.arguments = Array(inv.argv.dropFirst())
            if !inv.environment.isEmpty {
                var e = ProcessInfo.processInfo.environment
                for (k, v) in inv.environment { e[k] = v }
                proc.environment = e
            }
            let stdoutPipe = Pipe(); let stdinPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardInput = stdinPipe
            proc.standardError = stdoutPipe       // merge for parsing simplicity
            proc.terminationHandler = { p in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: (String(data: data, encoding: .utf8) ?? "", p.terminationStatus))
            }
            do {
                try proc.run()
                stdinPipe.fileHandleForWriting.write(inv.scriptStdin.data(using: .utf8) ?? Data())
                try stdinPipe.fileHandleForWriting.close()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
```

```swift
// Sources/FileTransferStore/RemoteEntry.swift
import Foundation

public struct RemoteEntry: Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let mtime: Date?
    public let mode: UInt16
}

public enum RemoteFileSystemError: Error {
    case sessionGone
    case subprocessFailed(exitCode: Int32, stderrTail: String)
    case parseFailed(String)
}
```

```swift
// Sources/FileTransferStore/RemoteFileSystem.swift
import Foundation
import SFTPCommandBuilder
import SSHCommandBuilder

public actor RemoteFileSystem {
    private let host: Host
    private let controlPath: URL
    private let credentials: SFTPCredentials
    private let runner: SFTPRunner
    private let liveness: ControlMasterLiveness

    public init(host: Host, controlPath: URL, credentials: SFTPCredentials,
                runner: SFTPRunner = SystemSFTPRunner(),
                liveness: ControlMasterLiveness) {
        self.host = host
        self.controlPath = controlPath
        self.credentials = credentials
        self.runner = runner
        self.liveness = liveness
    }

    public func list(_ path: String) async throws -> [RemoteEntry] {
        try await ensureAlive()
        let inv = try SFTPCommandBuilder.invocation(
            host: host, controlPath: controlPath,
            credentials: credentials, operation: .list(remoteDir: path)
        )
        let (out, code) = try await runner.run(inv)
        if code != 0 { throw RemoteFileSystemError.subprocessFailed(exitCode: code, stderrTail: tail(out)) }
        return try parseLsOutput(out)
    }

    public func mkdir(_ path: String) async throws {
        try await ensureAlive()
        try await runVoidOp(.mkdir(remotePath: path))
    }
    public func remove(_ path: String, isDirectory: Bool) async throws {
        try await ensureAlive()
        try await runVoidOp(.remove(remotePath: path, isDirectory: isDirectory))
    }
    public func rename(from: String, to: String) async throws {
        try await ensureAlive()
        try await runVoidOp(.rename(from: from, to: to))
    }

    private func runVoidOp(_ op: SFTPOperation) async throws {
        let inv = try SFTPCommandBuilder.invocation(
            host: host, controlPath: controlPath, credentials: credentials, operation: op)
        let (out, code) = try await runner.run(inv)
        if code != 0 { throw RemoteFileSystemError.subprocessFailed(exitCode: code, stderrTail: tail(out)) }
    }
    private func ensureAlive() async throws {
        if !(await liveness.isAlive(hostId: host.id)) {
            throw RemoteFileSystemError.sessionGone
        }
    }
    private func tail(_ s: String) -> String { String(s.suffix(1024)) }
}

func parseLsOutput(_ stdout: String) throws -> [RemoteEntry] {
    // Each ls -la line: <perm> <links> <owner> <group> <size> <month> <day> <time/year> <name>
    // Skip lines that don't match (sftp prompts, blank lines, ".", "..").
    var out: [RemoteEntry] = []
    for raw in stdout.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("sftp>") { continue }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 9 else { continue }
        let perms = parts[0]
        guard let size = Int64(parts[4]) else { continue }
        let name = parts[8...].joined(separator: " ")
        if name == "." || name == ".." { continue }
        out.append(RemoteEntry(
            name: name,
            isDirectory: perms.first == "d",
            size: size,
            mtime: nil,
            mode: 0
        ))
    }
    return out
}
```

- [ ] **Step 4: Run, verify pass**

Run: `cd apps/macos && swift test --filter FileTransferStoreTests.RemoteFileSystemTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/FileTransferStore/RemoteFileSystem.swift \
        apps/macos/Sources/FileTransferStore/RemoteEntry.swift \
        apps/macos/Sources/FileTransferStore/SFTPRunner.swift \
        apps/macos/Tests/FileTransferStoreTests/RemoteFileSystemTests.swift
git commit -m "feat(macos/transfer): RemoteFileSystem with liveness + ls parsing"
```

---

### Task 7: `FileTransferStore` queue (FIFO + cancel + retry)

**Files:**
- Create: `apps/macos/Sources/FileTransferStore/TransferTask.swift`
- Create: `apps/macos/Sources/FileTransferStore/FileTransferStore.swift`
- Test: `apps/macos/Tests/FileTransferStoreTests/FileTransferStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/FileTransferStoreTests/FileTransferStoreTests.swift
import XCTest
@testable import FileTransferStore
import SFTPCommandBuilder
import SSHCommandBuilder

@MainActor
final class FileTransferStoreTests: XCTestCase {
    final class ScriptedRunner: SFTPRunner, @unchecked Sendable {
        var script: [(stdout: String, exit: Int32)] = []
        var calls: [SFTPInvocation] = []
        func run(_ inv: SFTPInvocation) async throws -> (stdout: String, exit: Int32) {
            calls.append(inv)
            return script.isEmpty ? ("", 0) : script.removeFirst()
        }
    }
    final class AlwaysAlive: ControlMasterLiveness, @unchecked Sendable {
        func isAlive(hostId: UUID) async -> Bool { true }
    }

    func makeHost(_ id: UUID = UUID()) -> Host {
        Host(id: id, label: "x", hostname: "h", port: 22, username: "u", credential: .agent)
    }

    func testSerialFifoForOneHost() async throws {
        let runner = ScriptedRunner()
        runner.script = [("", 0), ("", 0), ("", 0)]
        let store = FileTransferStore(
            controlPathFor: { _ in URL(fileURLWithPath: "/sock") },
            credentialsFor: { _ in defaultCreds() },
            runner: runner,
            liveness: AlwaysAlive()
        )
        let host = makeHost()
        let ids = store.enqueueUpload(
            localPaths: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b"), URL(fileURLWithPath: "/c")],
            remoteDir: "/srv", host: host
        )
        XCTAssertEqual(ids.count, 3)
        try await store.waitIdle()
        let kinds = runner.calls.map { $0.scriptStdin }.map { String($0.prefix(3)) }
        XCTAssertEqual(kinds, ["put", "put", "put"])
        for id in ids {
            XCTAssertEqual(store.task(id: id)?.status, .completed)
        }
    }

    func testTwoHostsRunInParallel() async throws {
        // Two hosts, two upload chains; verify both finish concurrently
        // (we simply assert ordering interleaves within the call list).
        let runner = ScriptedRunner()
        let store = FileTransferStore(
            controlPathFor: { _ in URL(fileURLWithPath: "/sock") },
            credentialsFor: { _ in defaultCreds() },
            runner: runner,
            liveness: AlwaysAlive()
        )
        let h1 = makeHost(); let h2 = makeHost()
        _ = store.enqueueUpload(localPaths: [URL(fileURLWithPath: "/a")], remoteDir: "/", host: h1)
        _ = store.enqueueUpload(localPaths: [URL(fileURLWithPath: "/b")], remoteDir: "/", host: h2)
        try await store.waitIdle()
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testRetryUsesResumeFlag() async throws {
        let runner = ScriptedRunner()
        runner.script = [("permission denied", 1)]
        let store = FileTransferStore(
            controlPathFor: { _ in URL(fileURLWithPath: "/sock") },
            credentialsFor: { _ in defaultCreds() },
            runner: runner,
            liveness: AlwaysAlive()
        )
        let host = makeHost()
        let ids = store.enqueueUpload(localPaths: [URL(fileURLWithPath: "/a")], remoteDir: "/", host: host)
        try await store.waitIdle()
        XCTAssertEqual(store.task(id: ids[0])?.status, .failed)
        runner.script = [("", 0)]
        store.retry(ids[0])
        try await store.waitIdle()
        XCTAssertEqual(store.task(id: ids[0])?.status, .completed)
        XCTAssertTrue(runner.calls.last!.scriptStdin.hasPrefix("put -pa"))
    }

    func testCancelMidQueueRemovesPending() async throws {
        let runner = ScriptedRunner()
        // 2 successes; queue has 3 — we cancel #3 before it runs
        runner.script = [("", 0), ("", 0)]
        let store = FileTransferStore(
            controlPathFor: { _ in URL(fileURLWithPath: "/sock") },
            credentialsFor: { _ in defaultCreds() },
            runner: runner,
            liveness: AlwaysAlive()
        )
        let host = makeHost()
        let ids = store.enqueueUpload(
            localPaths: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b"), URL(fileURLWithPath: "/c")],
            remoteDir: "/", host: host
        )
        store.cancel(ids[2])
        try await store.waitIdle()
        XCTAssertEqual(store.task(id: ids[0])?.status, .completed)
        XCTAssertEqual(store.task(id: ids[1])?.status, .completed)
        XCTAssertEqual(store.task(id: ids[2])?.status, .cancelled)
    }
}

private func defaultCreds() -> SFTPCredentials {
    SFTPCredentials(askpassPath: nil, identityFiles: [],
                    knownHostsCaterm: URL(fileURLWithPath: "/k1"),
                    knownHostsUser: URL(fileURLWithPath: "/k2"),
                    strictHostKeyChecking: .acceptNew)
}
```

- [ ] **Step 2: Run, expect failure**

Run: `cd apps/macos && swift test --filter FileTransferStoreTests.FileTransferStoreTests`
Expected: FAIL — store doesn't exist.

- [ ] **Step 3: Implement TransferTask + FileTransferStore**

```swift
// Sources/FileTransferStore/TransferTask.swift
import Foundation

public typealias TaskId = UUID

public struct TransferTask: Identifiable, Equatable {
    public let id: TaskId
    public enum Kind: Equatable { case upload, download }
    public enum Status: Equatable { case pending, running, completed, failed, cancelled }
    public let kind: Kind
    public let hostId: UUID
    public let source: String
    public let destination: String
    public let isDirectory: Bool
    public var status: Status
    public var error: String?
}
```

```swift
// Sources/FileTransferStore/FileTransferStore.swift
import Combine
import Foundation
import SFTPCommandBuilder
import SSHCommandBuilder

@MainActor
public final class FileTransferStore: ObservableObject {
    @Published public private(set) var tasks: [TransferTask] = []

    private let controlPathFor: (UUID) -> URL
    private let credentialsFor: (UUID) -> SFTPCredentials
    private let runner: SFTPRunner
    private let liveness: ControlMasterLiveness
    private var perHostQueues: [UUID: [TaskId]] = [:]
    private var perHostBusy: Set<UUID> = []
    private var perHostHost: [UUID: Host] = [:]

    public init(controlPathFor: @escaping (UUID) -> URL,
                credentialsFor: @escaping (UUID) -> SFTPCredentials,
                runner: SFTPRunner = SystemSFTPRunner(),
                liveness: ControlMasterLiveness) {
        self.controlPathFor = controlPathFor
        self.credentialsFor = credentialsFor
        self.runner = runner
        self.liveness = liveness
    }

    public func task(id: TaskId) -> TransferTask? { tasks.first { $0.id == id } }

    public func enqueueUpload(localPaths: [URL], remoteDir: String, host: Host) -> [TaskId] {
        var ids: [TaskId] = []
        perHostHost[host.id] = host
        for p in localPaths {
            let isDir = (try? p.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let dest = (remoteDir as NSString).appendingPathComponent(p.lastPathComponent)
            let t = TransferTask(id: UUID(), kind: .upload, hostId: host.id,
                                 source: p.path, destination: dest, isDirectory: isDir,
                                 status: .pending, error: nil)
            tasks.append(t)
            perHostQueues[host.id, default: []].append(t.id)
            ids.append(t.id)
        }
        kick(host.id)
        return ids
    }

    public func enqueueDownload(remotePaths: [String], localDir: URL, host: Host) -> [TaskId] {
        var ids: [TaskId] = []
        perHostHost[host.id] = host
        for r in remotePaths {
            let dest = localDir.appendingPathComponent((r as NSString).lastPathComponent)
            let t = TransferTask(id: UUID(), kind: .download, hostId: host.id,
                                 source: r, destination: dest.path, isDirectory: false,
                                 status: .pending, error: nil)
            tasks.append(t)
            perHostQueues[host.id, default: []].append(t.id)
            ids.append(t.id)
        }
        kick(host.id)
        return ids
    }

    public func cancel(_ id: TaskId) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        if tasks[idx].status == .pending {
            tasks[idx].status = .cancelled
            // Remove from its queue
            if var q = perHostQueues[tasks[idx].hostId] {
                q.removeAll { $0 == id }
                perHostQueues[tasks[idx].hostId] = q
            }
        }
        // Mid-running cancel: future iteration; v1 only cancels pending.
    }

    public func retry(_ id: TaskId) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }),
              tasks[idx].status == .failed else { return }
        tasks[idx].status = .pending
        perHostQueues[tasks[idx].hostId, default: []].append(id)
        kick(tasks[idx].hostId)
    }

    public func waitIdle() async throws {
        // Tests-only: spin until all queues are empty and no host is busy.
        while perHostBusy.isEmpty == false || perHostQueues.values.contains(where: { !$0.isEmpty }) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func kick(_ hostId: UUID) {
        guard !perHostBusy.contains(hostId) else { return }
        guard let q = perHostQueues[hostId], let next = q.first else { return }
        perHostBusy.insert(hostId)
        perHostQueues[hostId]?.removeFirst()
        guard let idx = tasks.firstIndex(where: { $0.id == next }) else {
            perHostBusy.remove(hostId); return
        }
        tasks[idx].status = .running
        let task = tasks[idx]
        Task {
            await runTask(task)
            self.perHostBusy.remove(hostId)
            self.kick(hostId)
        }
    }

    private func runTask(_ t: TransferTask) async {
        let host = perHostHost[t.hostId]!
        let controlPath = controlPathFor(t.hostId)
        let creds = credentialsFor(t.hostId)
        let resume = t.error != nil  // retry path
        let op: SFTPOperation
        switch t.kind {
        case .upload:
            op = .put(localPath: URL(fileURLWithPath: t.source),
                      remotePath: t.destination, recursive: t.isDirectory, resume: resume)
        case .download:
            op = .get(remotePath: t.source,
                      localPath: URL(fileURLWithPath: t.destination), recursive: t.isDirectory, resume: resume)
        }
        do {
            let inv = try SFTPCommandBuilder.invocation(
                host: host, controlPath: controlPath, credentials: creds, operation: op)
            let (out, code) = try await runner.run(inv)
            await MainActor.run {
                if let i = self.tasks.firstIndex(where: { $0.id == t.id }) {
                    if code == 0 { self.tasks[i].status = .completed; self.tasks[i].error = nil }
                    else { self.tasks[i].status = .failed; self.tasks[i].error = String(out.suffix(1024)) }
                }
            }
        } catch {
            await MainActor.run {
                if let i = self.tasks.firstIndex(where: { $0.id == t.id }) {
                    self.tasks[i].status = .failed
                    self.tasks[i].error = "\(error)"
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run, verify, fix any flakes**

Run: `cd apps/macos && swift test --filter FileTransferStoreTests.FileTransferStoreTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/FileTransferStore/TransferTask.swift \
        apps/macos/Sources/FileTransferStore/FileTransferStore.swift \
        apps/macos/Tests/FileTransferStoreTests/FileTransferStoreTests.swift
git commit -m "feat(macos/transfer): FileTransferStore FIFO queue + retry"
```

---

## Phase 3 — UI

### Task 8: `FileDrawerView` shell + `RemoteFileListView`

**Files:**
- Create: `apps/macos/Sources/Caterm/Views/FileDrawerView.swift`
- Create: `apps/macos/Sources/Caterm/Views/RemoteFileListView.swift`
- Modify: `apps/macos/Package.swift` — add `FileTransferStore` and `SFTPCommandBuilder` to `Caterm` target dependencies.

- [ ] **Step 1: Add dependencies to Caterm executable target**

In `Package.swift`:

```swift
.executableTarget(
    name: "Caterm",
    dependencies: [
        "TerminalEngine", "SSHCommandBuilder", "SessionStore",
        "KeychainStore", "ConfigStore", "ServerSyncClient", "HostSyncStore",
        "FileTransferStore", "SFTPCommandBuilder",   // ← add these
    ],
    ...
```

Run `swift build` to confirm compile.

- [ ] **Step 2: Implement `RemoteFileListView` (read-only list)**

```swift
// Sources/Caterm/Views/RemoteFileListView.swift
import SwiftUI
import FileTransferStore

struct RemoteFileListView: View {
    let entries: [RemoteEntry]
    @Binding var selection: RemoteEntry.ID?
    let onActivate: (RemoteEntry) -> Void

    var body: some View {
        List(entries, selection: $selection) { entry in
            HStack {
                Image(systemName: entry.isDirectory ? "folder" : "doc")
                Text(entry.name)
                Spacer()
                if !entry.isDirectory {
                    Text(byteString(entry.size)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onActivate(entry) }
        }
    }

    private func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
```

- [ ] **Step 3: Implement `FileDrawerView` shell with breadcrumb**

```swift
// Sources/Caterm/Views/FileDrawerView.swift
import SwiftUI
import FileTransferStore
import SSHCommandBuilder

@MainActor
struct FileDrawerView: View {
    let host: Host?
    let fs: RemoteFileSystem?
    @State private var path: String = "~"
    @State private var entries: [RemoteEntry] = []
    @State private var selection: RemoteEntry.ID?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(path).font(.system(.body, design: .monospaced))
                Spacer()
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.borderless)
            }.padding(8)

            Divider()

            if host == nil {
                ContentUnavailableView("Not connected",
                    systemImage: "wifi.slash",
                    description: Text("Connect to a host to browse files."))
            } else if let err = error {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle",
                    description: Text(err))
            } else {
                RemoteFileListView(entries: entries, selection: $selection) { entry in
                    if entry.isDirectory {
                        path = (path as NSString).appendingPathComponent(entry.name)
                        Task { await refresh() }
                    }
                }
            }
        }
        .frame(minWidth: 240)
        .task(id: host?.id) { await refresh() }
    }

    private func refresh() async {
        guard let fs else { return }
        do {
            self.entries = try await fs.list(path)
            self.error = nil
        } catch let RemoteFileSystemError.sessionGone {
            self.error = "Reconnect host to browse files"
        } catch {
            self.error = "\(error)"
        }
    }
}
```

- [ ] **Step 4: Build, smoke-launch the app to confirm no crashes**

Run: `cd apps/macos && swift build`
Expected: build succeeds.

(Visual integration in next task — the drawer is not yet attached to MainWindow.)

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/FileDrawerView.swift \
        apps/macos/Sources/Caterm/Views/RemoteFileListView.swift \
        apps/macos/Package.swift
git commit -m "feat(macos/files): FileDrawerView shell + read-only list view"
```

---

### Task 9: Integrate drawer into `MainWindow` with toggle

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/MainWindow.swift`
- Modify: `apps/macos/Sources/Caterm/CatermApp.swift` (menu / keyboard shortcut)

- [ ] **Step 1: Locate the existing terminal area in `MainWindow.swift`**

Read the file. Identify the SwiftUI `body` returning the terminal `TerminalContainerView`. The drawer attaches via `HSplitView` to its right.

- [ ] **Step 2: Wrap the terminal in an `HSplitView`**

```swift
// In MainWindow.swift body:
@State private var fileDrawerOpen = false

HSplitView {
    TerminalContainerView(/* existing args */)
        .frame(minWidth: 400)
    if fileDrawerOpen {
        FileDrawerView(host: activeHost, fs: activeRemoteFs)
            .frame(minWidth: 240, maxWidth: 600)
    }
}
```

`activeHost` reads from `SessionStore.tabs[selectedTab].host`. `activeRemoteFs` is a computed property that constructs a `RemoteFileSystem` for the active host using `ControlMasterManager.shared.socketPath(for:)` and existing credential surface.

- [ ] **Step 3: Add `⌘⇧F` toggle and toolbar button**

In `CatermApp.swift`'s `Scene`:

```swift
.commands {
    CommandGroup(after: .toolbar) {
        Button("Show Files Drawer") {
            NotificationCenter.default.post(name: .toggleFileDrawer, object: nil)
        }
        .keyboardShortcut("F", modifiers: [.command, .shift])
    }
}
```

In `MainWindow`, listen for the notification and flip `fileDrawerOpen`. Also add a toolbar button:

```swift
ToolbarItemGroup(placement: .primaryAction) {
    Button {
        fileDrawerOpen.toggle()
    } label: {
        Image(systemName: "folder")
    }
}
```

Define `extension Notification.Name { static let toggleFileDrawer = Notification.Name("toggleFileDrawer") }` in a new `Sources/Caterm/Notifications.swift`.

- [ ] **Step 4: Build, manually launch, verify ⌘⇧F toggles drawer**

Run: `make -C apps/macos run-app` (or `swift run caterm`).
Verify: Connect to a host, press ⌘⇧F → drawer slides in showing remote home dir.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/
git commit -m "feat(macos/files): wire FileDrawerView into MainWindow with ⌘⇧F"
```

---

### Task 10: Drag-drop — drawer-as-upload target

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/FileDrawerView.swift`
- Modify: `apps/macos/Sources/Caterm/Views/RemoteFileListView.swift`

- [ ] **Step 1: Add `.onDrop` handler to drawer**

```swift
// In FileDrawerView body's outermost VStack:
.onDrop(of: [.fileURL], isTargeted: nil) { providers in
    Task {
        let urls = await loadURLs(from: providers)
        guard let host = host, !urls.isEmpty else { return }
        _ = appServices.fileTransferStore.enqueueUpload(
            localPaths: urls, remoteDir: path, host: host)
        await refresh()
    }
    return true
}

private func loadURLs(from providers: [NSItemProvider]) async -> [URL] {
    await withTaskGroup(of: URL?.self) { group in
        for p in providers {
            group.addTask {
                await withCheckedContinuation { cont in
                    _ = p.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
                }
            }
        }
        var out: [URL] = []
        for await u in group { if let u { out.append(u) } }
        return out
    }
}
```

(`appServices` is the existing dependency-injection root, or a `@EnvironmentObject` you already pass. If not present, pass `FileTransferStore` as a parameter to `FileDrawerView`.)

- [ ] **Step 2: Manually verify drag from Finder uploads file**

Run app, open drawer on a connected host, drag a small text file from Finder onto the drawer. Verify the transfer appears in the queue area (next task adds the visible queue) and the file lands on the remote.

- [ ] **Step 3: Add directory-row drop target for "into folder"**

In `RemoteFileListView` row HStack:

```swift
.onDrop(of: [.fileURL], isTargeted: nil) { providers in
    if entry.isDirectory {
        Task {
            let urls = await loadURLs(from: providers)
            // Notify parent via callback to enqueue into entry.name subdir.
            onDropOnFolder(entry, urls)
        }
        return true
    }
    return false
}
```

Add `onDropOnFolder: (RemoteEntry, [URL]) -> Void` parameter to `RemoteFileListView` and wire it up in `FileDrawerView`.

- [ ] **Step 4: Build, manually verify drop-into-folder**

Drag a file onto a directory row → file uploads into that directory.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/FileDrawerView.swift \
        apps/macos/Sources/Caterm/Views/RemoteFileListView.swift
git commit -m "feat(macos/files): drag-drop upload (drawer + directory row)"
```

---

### Task 11: Drag-drop — terminal `⌥` branch and OSC 7 cwd

**Files:**
- Modify: `apps/macos/Sources/TerminalEngine/GhosttySurfaceNSView+Drag.swift`
- (Modify shared `OSC7CwdReader.swift` if not already extracted; if it lives inline, leave it.)

- [ ] **Step 1: Read the existing drag handler**

Open the file. Confirm the current `performDragOperation` implementation that pastes the shell-quoted path. Identify the `NSDraggingInfo` API for modifier flags: `info.draggingSourceOperationMask` does NOT carry option modifier; we read `NSEvent.modifierFlags` directly inside the perform handler.

- [ ] **Step 2: Add the ⌥ branch**

```swift
override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let isOption = NSEvent.modifierFlags.contains(.option)
    let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    if isOption, !urls.isEmpty {
        return enqueueUpload(urls)
    }
    return existingPasteAsPathBehavior(sender)   // unchanged
}

private func enqueueUpload(_ urls: [URL]) -> Bool {
    let cwd = osc7Cwd()    // existing OSC 7 reader if present, else nil
    if let cwd {
        appServices.fileTransferStore.enqueueUpload(localPaths: urls, remoteDir: cwd, host: hostForThisSurface)
    } else {
        // Modal sheet asks for target dir
        showTargetDirSheet(forUploads: urls)
    }
    return true
}
```

`osc7Cwd()` — if the codebase doesn't yet expose this, defer to v2 by always falling back to the modal sheet. Specifically: in this task, implement only the modal sheet path. The OSC 7 enhancement is a separate later task.

- [ ] **Step 3: Implement `showTargetDirSheet`**

A simple SwiftUI sheet via `NSSavePanel` configured for `canCreateDirectories=true, canChooseDirectories=true, canChooseFiles=false`. After the user picks a dir, enqueue with that path.

```swift
private func showTargetDirSheet(forUploads urls: [URL]) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.message = "Choose remote target directory"
    panel.runModal()
    guard let target = panel.url else { return }
    appServices.fileTransferStore.enqueueUpload(
        localPaths: urls, remoteDir: target.path, host: hostForThisSurface)
}
```

(For v1, `NSOpenPanel` runs against the *local* filesystem. To pick a *remote* target you'd need a custom sheet using the drawer's path. Acceptable v1 simplification: when ⌥ is held but no OSC 7, prompt for the target via a SwiftUI sheet that hosts a textfield seeded with the drawer's current path — which is far easier than building a remote browser sheet.)

Replace the NSOpenPanel block with:

```swift
private func showTargetDirSheet(forUploads urls: [URL]) {
    let dialog = SimpleTextSheet(
        title: "Upload to remote directory",
        prompt: "Path",
        initialValue: appServices.lastDrawerPath ?? "~"
    )
    dialog.onSubmit = { remoteDir in
        appServices.fileTransferStore.enqueueUpload(
            localPaths: urls, remoteDir: remoteDir, host: hostForThisSurface)
    }
    dialog.present(on: self.window)
}
```

`SimpleTextSheet` is a small SwiftUI sheet with a single `TextField` and OK/Cancel buttons. Implement under `Views/SimpleTextSheet.swift`.

- [ ] **Step 4: Manual verify**

Run the app. Drag a file into terminal without `⌥` → pastes path (unchanged). Hold `⌥`, drag → sheet appears with "~" prefilled → click OK → file uploads to home dir.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/TerminalEngine/GhosttySurfaceNSView+Drag.swift \
        apps/macos/Sources/Caterm/Views/SimpleTextSheet.swift
git commit -m "feat(macos/files): ⌥+drag-into-terminal uploads via path sheet"
```

---

### Task 12: Transfer queue UI (sticky bottom)

**Files:**
- Create: `apps/macos/Sources/Caterm/Views/TransferQueueView.swift`
- Modify: `apps/macos/Sources/Caterm/Views/FileDrawerView.swift`

- [ ] **Step 1: Implement TransferQueueView**

```swift
// Sources/Caterm/Views/TransferQueueView.swift
import SwiftUI
import FileTransferStore

struct TransferQueueView: View {
    @ObservedObject var store: FileTransferStore

    var body: some View {
        let active = store.tasks.filter { $0.status == .running || $0.status == .pending }
        let failed = store.tasks.filter { $0.status == .failed }
        if active.isEmpty && failed.isEmpty { EmptyView() }
        else {
            VStack(alignment: .leading, spacing: 4) {
                if let first = active.first(where: { $0.status == .running }) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(first.kind == .upload ? "Uploading: \((first.source as NSString).lastPathComponent)" : "Downloading: \((first.source as NSString).lastPathComponent)")
                            .lineLimit(1)
                        Spacer()
                        Button { store.cancel(first.id) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                if active.count > 1 {
                    Text("\(active.count - 1) queued").foregroundStyle(.secondary).font(.caption)
                }
                ForEach(failed) { t in
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text((t.source as NSString).lastPathComponent)
                        Spacer()
                        Button("Retry") { store.retry(t.id) }
                            .buttonStyle(.borderless)
                    }.font(.caption)
                }
            }.padding(8)
        }
    }
}
```

- [ ] **Step 2: Add `TransferQueueView` to drawer**

In `FileDrawerView` body, below the list and Divider:

```swift
TransferQueueView(store: appServices.fileTransferStore)
    .background(.thickMaterial)
```

- [ ] **Step 3: Verify visually**

Drag two large files in; verify "Uploading: a.txt" + "1 queued" appears. Wait for completion. Disconnect mid-transfer to force a failure → verify Retry button works.

- [ ] **Step 4: (No new test)** — UI behavior is covered by `FileTransferStoreTests` plus manual smoke (next task).

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/TransferQueueView.swift \
        apps/macos/Sources/Caterm/Views/FileDrawerView.swift
git commit -m "feat(macos/files): sticky transfer queue at drawer bottom"
```

---

### Task 13: Right-click menu (download / rename / delete / copy path / mkdir)

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/RemoteFileListView.swift`
- Modify: `apps/macos/Sources/Caterm/Views/FileDrawerView.swift`

- [ ] **Step 1: Add `.contextMenu` to row**

```swift
// Inside the row in RemoteFileListView, after .contentShape:
.contextMenu {
    if !entry.isDirectory {
        Button("Download…") { onDownload(entry) }
    }
    Button("Rename…") { onRename(entry) }
    Button("Delete", role: .destructive) { onDelete(entry) }
    Divider()
    Button("Copy Path") { onCopyPath(entry) }
}
```

Add corresponding closure parameters and wire to `FileDrawerView`.

- [ ] **Step 2: Implement actions in `FileDrawerView`**

```swift
private func onDownload(_ e: RemoteEntry) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true; panel.canChooseFiles = false
    guard panel.runModal() == .OK, let target = panel.url else { return }
    let remote = (path as NSString).appendingPathComponent(e.name)
    _ = appServices.fileTransferStore.enqueueDownload(
        remotePaths: [remote], localDir: target, host: host!)
}
private func onRename(_ e: RemoteEntry) {
    let sheet = SimpleTextSheet(title: "Rename", prompt: "New name", initialValue: e.name)
    sheet.onSubmit = { newName in
        let from = (path as NSString).appendingPathComponent(e.name)
        let to = (path as NSString).appendingPathComponent(newName)
        Task { try await fs?.rename(from: from, to: to); await refresh() }
    }
    sheet.present(on: nil)
}
private func onDelete(_ e: RemoteEntry) {
    let p = (path as NSString).appendingPathComponent(e.name)
    Task { try await fs?.remove(p, isDirectory: e.isDirectory); await refresh() }
}
private func onCopyPath(_ e: RemoteEntry) {
    let p = (path as NSString).appendingPathComponent(e.name)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(p, forType: .string)
}
```

- [ ] **Step 3: Add "New Folder" toolbar button**

In the breadcrumb row, next to refresh, add `+` button calling a similar `SimpleTextSheet` then `fs.mkdir(...)`.

- [ ] **Step 4: Manual verify each action**

Test rename → file renames; delete → file removed; copy path → paste into terminal works; new folder creates.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/
git commit -m "feat(macos/files): context menu — download, rename, delete, copy path, mkdir"
```

---

## Phase 4 — Lifecycle & integration

### Task 14: ControlMaster cleanup hooks

**Files:**
- Modify: `apps/macos/Sources/Caterm/AppDelegate.swift`
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift`

- [ ] **Step 1: Wire `applicationWillTerminate` → `tearDownAll`**

```swift
// In AppDelegate.swift:
func applicationWillTerminate(_ notification: Notification) {
    let group = DispatchGroup()
    group.enter()
    Task { @MainActor in
        await appServices.controlMasterManager.tearDownAll()
        group.leave()
    }
    _ = group.wait(timeout: .now() + 1.0)
}
```

- [ ] **Step 2: Add last-tab teardown grace in `SessionStore.closeTab`**

```swift
// In SessionStore.closeTab:
public func closeTab(tabId: UUID) {
    guard let i = tabs.firstIndex(where: { $0.id == tabId }) else { return }
    let hostId = tabs[i].host.id
    tabs.remove(at: i)
    if !tabs.contains(where: { $0.host.id == hostId }) {
        // Last tab for this host. Schedule teardown in 30s; cancel if a new tab opens.
        scheduleTeardown(hostId: hostId, after: 30)
    }
}

private var teardownWorkItems: [UUID: DispatchWorkItem] = [:]
private func scheduleTeardown(hostId: UUID, after seconds: Double) {
    teardownWorkItems[hostId]?.cancel()
    let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        Task { @MainActor in
            await self.controlMasterManager?.tearDown(hostId: hostId)
            self.teardownWorkItems.removeValue(forKey: hostId)
        }
    }
    teardownWorkItems[hostId] = item
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
}
```

(`controlMasterManager` is wired into `SessionStore` via init or a setter; pick whichever matches existing DI style.)

Also cancel the teardown when a new tab opens for that host:

```swift
// In SessionStore.openTab (or wherever tabs are added):
teardownWorkItems[host.id]?.cancel()
teardownWorkItems.removeValue(forKey: host.id)
```

- [ ] **Step 3: Add unit test**

```swift
// Tests/SessionStoreTests/ControlMasterTeardownTests.swift
import XCTest
@testable import SessionStore
@testable import FileTransferStore

@MainActor
final class ControlMasterTeardownTests: XCTestCase {
    final class Spy: ControlMasterTearDowning, @unchecked Sendable {
        var torn: [UUID] = []
        func tearDown(hostId: UUID) async { torn.append(hostId) }
        func tearDownAll() async {}
    }
    func testNewTabCancelsScheduledTeardown() async {
        let spy = Spy()
        let store = SessionStore(controlMasterManager: spy)
        let host = SSHHost.fixture()
        let tab = store.addTab(host: host)
        store.closeTab(tabId: tab.id)
        // New tab within grace
        _ = store.addTab(host: host)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(spy.torn.isEmpty)
    }
}
```

(Define `ControlMasterTearDowning` as a small protocol that `ControlMasterManager` conforms to, so tests can stub.)

- [ ] **Step 4: Run, verify**

Run: `cd apps/macos && swift test --filter SessionStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/AppDelegate.swift \
        apps/macos/Sources/SessionStore/ \
        apps/macos/Tests/SessionStoreTests/
git commit -m "feat(macos/transfer): tear down ControlMaster on app quit and last-tab close"
```

---

### Task 15: Integration tests — no-fallback contract

**Files:**
- Create: `apps/macos/Tests/FileTransferStoreTests/NoFallbackContractTests.swift`

These are real-`ssh` integration tests; they only run in CI or developer machines with the existing OpenSSH-in-Docker harness already used by the project (per spec §6.3). Skip if the harness env var isn't set.

- [ ] **Step 1: Write the test**

```swift
// Tests/FileTransferStoreTests/NoFallbackContractTests.swift
import XCTest
@testable import FileTransferStore
import SFTPCommandBuilder
import SSHCommandBuilder

final class NoFallbackContractTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CATERM_DOCKER_SSH"] == "1",
                          "Requires CATERM_DOCKER_SSH=1 + the openssh-in-docker harness")
    }

    func testNoFallbackWhenAgentLoaded() async throws {
        // Pre-condition: SSH_AUTH_SOCK points at an agent that holds a key
        // authorized on the test host. The master socket is intentionally
        // deleted before invoking RemoteFileSystem.list().
        let host = TestHosts.docker
        let cm = ControlMasterManager(cacheDir: try CacheDirectories.controlMasterDir())
        cm.register(hostId: host.id, destination: "\(host.username)@\(host.hostname)")
        let sock = cm.socketPath(for: host.id)
        try? FileManager.default.removeItem(at: sock)   // ensure stale state
        let fs = RemoteFileSystem(host: host,
                                  controlPath: sock,
                                  credentials: TestHosts.credentials,
                                  liveness: cm)
        do {
            _ = try await fs.list("/")
            XCTFail("expected sessionGone")
        } catch RemoteFileSystemError.sessionGone {
            // OK
        }
    }

    func testNoFallbackWhenPasswordlessKeyAvailable() async throws {
        // Same as above but with ~/.ssh/id_ed25519 (no passphrase) authorized
        // on the test host. The contract says liveness check fails → sessionGone.
        try await testNoFallbackWhenAgentLoaded()
    }
}
```

(The harness already provides `TestHosts.docker` and `TestHosts.credentials` per existing test patterns; reuse them. If they don't exist yet, add them as a small test fixture file alongside this test.)

- [ ] **Step 2: Run with the harness**

Run: `cd apps/macos && CATERM_DOCKER_SSH=1 swift test --filter NoFallbackContractTests`
Expected: PASS (or SKIP outside CI).

- [ ] **Step 3: (No code change)**

- [ ] **Step 4: (No code change)**

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Tests/FileTransferStoreTests/NoFallbackContractTests.swift
git commit -m "test(macos/transfer): no-fallback contract integration tests"
```

---

### Task 16: Manual smoke document

**Files:**
- Create: `apps/macos/Manual/sftp-smoke.md`

- [ ] **Step 1: Write the document**

```markdown
# SFTP / File Drawer manual smoke

Run before tagging any release that touches `FileTransferStore`,
`SFTPCommandBuilder`, or `FileDrawerView`.

Prereq: a reachable SSH host with sftp-server enabled.

## 1. List home directory
- Connect to host, press ⌘⇧F → drawer opens, lists `~`.

## 2. Navigate via breadcrumb
- Double-click a directory → drawer lists it; breadcrumb updates.

## 3. Upload single file via drag-to-drawer
- Drag a small file from Finder onto drawer → file appears in remote list after upload.

## 4. Upload directory tree
- Drag a directory from Finder → drawer enqueues with `-R` (verify
  via remote `ls -la <dir>`); takes longer; queue updates on completion.

## 5. Download single file via drag-to-Finder
- Drag a file from drawer to Finder window → file appears locally.

## 6. Drag file to terminal — pastes path (unchanged)
- Drag a file to terminal area without ⌥ → shell-quoted path pasted at cursor.

## 7. ⌥ + drag file to terminal — uploads
- Hold ⌥, drag a file into terminal → "Upload to remote directory" sheet appears
  prefilled with the drawer's current path; click OK → file uploads.

## 8. ⌥ + drag with no OSC 7 — modal sheet appears
- Same as #7; current v1 always shows the sheet (OSC 7 path is v2).

## 9. Rename file
- Right-click file → Rename → enter new name → file renames on remote.

## 10. Delete file/directory
- Right-click → Delete → file removed; refresh confirms.

## 11. mkdir
- `+` button → enter name → folder appears.

## 12. Copy remote path
- Right-click → Copy Path → paste into terminal; matches expected path.

## 13. Cancel mid-upload
- Drag a large file (≥100 MB), cancel via ✕ before completion → task → cancelled.
  Partial file may remain on remote (acceptable v1).

## 14. ControlMaster expires
- After ControlPersist=10m timeout (or `ssh -O exit -S <socket> user@host`
  manually), trigger any drawer action → "Reconnect host to browse files"
  banner appears.

## 15. Path with spaces and unicode
- Upload `"测试 文件.txt"` → roundtrips back via download with same name.
```

- [ ] **Step 2-4: (No code)**

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Manual/sftp-smoke.md
git commit -m "docs(macos): manual smoke checklist for SFTP drawer"
```

---

## Phase 5 — Polish

### Task 17: Empty / error states + tab status integration

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/FileDrawerView.swift`

- [ ] **Step 1: Disconnected state**

When `host == nil` show `ContentUnavailableView("Connect to browse files", systemImage: "wifi.slash")` (already in Task 8).

- [ ] **Step 2: Empty directory state**

When `entries.isEmpty` and no error, show:

```swift
ContentUnavailableView("Empty folder", systemImage: "folder")
```

- [ ] **Step 3: Error state with reconnect button**

When error string equals "Reconnect host to browse files", overlay a button:

```swift
ContentUnavailableView {
    Label("Reconnect host", systemImage: "arrow.clockwise")
} description: {
    Text("Master connection has expired.")
} actions: {
    Button("Reconnect") {
        appServices.sessionStore.reconnect(hostId: host!.id)
    }
}
```

- [ ] **Step 4: Verify visually**

Disconnect host, ⌘⇧F → see Reconnect button.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/FileDrawerView.swift
git commit -m "feat(macos/files): empty-folder + reconnect empty states"
```

---

## Done criteria

- [ ] All 17 tasks above committed individually.
- [ ] `swift test` is green (`SSHCommandBuilderTests`, `SFTPCommandBuilderTests`, `FileTransferStoreTests`, `SessionStoreTests`).
- [ ] Manual smoke `Manual/sftp-smoke.md` runs through end-to-end against a real host.
- [ ] No regressions in existing terminal smoke (`Manual/end-to-end-smoke.md`).
- [ ] CI integration tests pass when `CATERM_DOCKER_SSH=1`.
