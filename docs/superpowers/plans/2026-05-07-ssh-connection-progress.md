# SSH Connection Progress UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Termius-style overlay during SSH connect with two phases (`Connecting…` / `Authenticating…`), specific error messages on failure, and Retry / Edit Host actions.

**Architecture:** TCP preflight via `NWConnection` (Network.framework) decides reachability before launching libghostty's ssh subprocess. Two phases: `.preflight` (probe) and `.authenticating` (ssh process running). Failures surface a `FailureOverlay`; success fades the overlay out.

**Tech Stack:** Swift Package Manager (apps/macos), SwiftUI views, XCTest, `Network.framework`. macOS 14+ target.

**Spec:** `docs/superpowers/specs/2026-05-07-ssh-connection-progress-design.md`

---

## File Map

**Create:**
- `apps/macos/Sources/SessionStore/Preflight.swift`
- `apps/macos/Sources/SessionStore/PreflightProbing.swift`
- `apps/macos/Sources/Caterm/Views/ConnectingOverlay.swift`
- `apps/macos/Sources/Caterm/Views/FailureOverlay.swift`
- `apps/macos/Sources/Caterm/Views/FailurePresentation.swift`
- `apps/macos/Sources/Caterm/Views/EditHostNotification.swift`
- `apps/macos/Tests/SessionStoreTests/PreflightTests.swift`
- `apps/macos/Tests/SessionStoreTests/SessionStoreConnectionFlowTests.swift`
- `apps/macos/Tests/CatermTests/FailurePresentationTests.swift`
- `apps/macos/Manual/connection-progress-checklist.md`

**Modify:**
- `apps/macos/Sources/SessionStore/ConnectionState.swift` — replace `.connecting` with `.preflight` + `.authenticating`
- `apps/macos/Sources/SessionStore/FailureKind.swift` — add `.networkUnreachable(NetworkErrorReason)` + the enum
- `apps/macos/Sources/SessionStore/SessionStore.swift` — add `startConnection`, `retryTab`, attempt token, inject `PreflightProbing`; rewire `openTab` and `scheduleReconnect`
- `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift` — state-driven surface vs placeholder + overlay routing
- `apps/macos/Sources/Caterm/Views/HostListSidebar.swift` — add `.onReceive(.catermEditHostRequested)`
- `apps/macos/Sources/Caterm/Views/HostFormView.swift` — port range 1–65535
- `apps/macos/Tests/SessionStoreTests/EndToEndSSHTests.swift` — replace `markConnecting` with new API

**No Package.swift changes.** `Network.framework` auto-links from `import Network` on macOS.

---

## Task 1: Add `NetworkErrorReason` and `FailureKind.networkUnreachable`

**Files:**
- Modify: `apps/macos/Sources/SessionStore/FailureKind.swift`
- Modify: `apps/macos/Sources/SessionStore/ReconnectScheduler.swift` (the existing `shouldReconnect` switch goes non-exhaustive once we add the new case — extend it)
- Test: `apps/macos/Tests/SessionStoreTests/FailureKindTests.swift` (will create — there is no existing file for this)

- [ ] **Step 1: Write the failing test**

Create `apps/macos/Tests/SessionStoreTests/FailureKindTests.swift`:

```swift
import XCTest
@testable import SessionStore

final class FailureKindTests: XCTestCase {
    func testClassifyExitZeroIsCleanExit() {
        XCTAssertEqual(FailureKind.classify(exitCode: 0, hadConnected: false), .cleanExit)
        XCTAssertEqual(FailureKind.classify(exitCode: 0, hadConnected: true), .cleanExit)
    }

    func testClassifyAfterConnectedIsConnectionDropped() {
        XCTAssertEqual(FailureKind.classify(exitCode: 1, hadConnected: true), .connectionDropped)
    }

    func testClassifyBeforeConnectedIsAuthOrSetupFail() {
        XCTAssertEqual(FailureKind.classify(exitCode: 255, hadConnected: false), .authOrSetupFail)
    }

    func testNetworkErrorReasonEquality() {
        XCTAssertEqual(NetworkErrorReason.dnsFailed, .dnsFailed)
        XCTAssertNotEqual(NetworkErrorReason.dnsFailed, .timedOut)
        XCTAssertEqual(NetworkErrorReason.invalidPort(99999), .invalidPort(99999))
        XCTAssertNotEqual(NetworkErrorReason.invalidPort(99999), .invalidPort(0))
        XCTAssertEqual(
            NetworkErrorReason.other(code: 1, message: "x"),
            .other(code: 1, message: "x")
        )
    }

    func testFailureKindNetworkUnreachableEquality() {
        XCTAssertEqual(
            FailureKind.networkUnreachable(.dnsFailed),
            FailureKind.networkUnreachable(.dnsFailed)
        )
        XCTAssertNotEqual(
            FailureKind.networkUnreachable(.dnsFailed),
            FailureKind.networkUnreachable(.timedOut)
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
cd apps/macos && swift test --filter SessionStoreTests.FailureKindTests
```

Expected: build error — `NetworkErrorReason` is not defined and `FailureKind.networkUnreachable` doesn't exist.

- [ ] **Step 3: Modify `FailureKind.swift`**

Replace contents of `apps/macos/Sources/SessionStore/FailureKind.swift`:

```swift
import Foundation

public enum FailureKind: Equatable {
    /// auth fail or host key mismatch or DNS — short-lived, never reached Connected.
    /// UI: red, "重新填凭据"; do NOT auto-reconnect.
    case authOrSetupFail

    /// Remote shell exited with `exit` (status 0). UI: grey "会话结束"; no reconnect.
    case cleanExit

    /// Network drop after Connected. UI: yellow; enter §4.3 reconnect FSM.
    case connectionDropped

    /// TCP preflight failed before ssh subprocess was launched. Carries a
    /// typed reason for user-facing copy. Does NOT auto-reconnect — initial
    /// network-unreachable means user-visible error with manual Retry.
    case networkUnreachable(NetworkErrorReason)

    /// Classify exit_code + connected-history into one of three exit-driven
    /// failures. `.networkUnreachable` is constructed directly by
    /// `SessionStore.startConnection` and never enters this path.
    public static func classify(exitCode: Int32, hadConnected: Bool) -> FailureKind {
        if exitCode == 0 { return .cleanExit }
        if hadConnected { return .connectionDropped }
        return .authOrSetupFail
    }
}

public enum NetworkErrorReason: Equatable {
    /// Hostname could not be resolved.
    case dnsFailed
    /// Host reachable but port not accepting connections (`ECONNREFUSED`).
    case connectionRefused
    /// Probe timed out (no SYN-ACK or NWConnection waiting state past timeout).
    case timedOut
    /// Local network down / route unreachable (`ENETDOWN`/`ENETUNREACH`/`EHOSTUNREACH`).
    case networkDown
    /// Persisted host port is outside 1...65535. Carried as Int because the
    /// invalid value itself is informational (UI shows "Port X is out of range").
    case invalidPort(Int)
    /// Catch-all: NWError that didn't match any specific case above.
    case other(code: Int, message: String)
}
```

- [ ] **Step 4: Update `ReconnectScheduler` for the new case**

In `apps/macos/Sources/SessionStore/ReconnectScheduler.swift`, replace the `shouldReconnect` body so the switch stays exhaustive:

Old:
```swift
public static func shouldReconnect(failureKind: FailureKind, attempt: Int) -> Bool {
    guard attempt <= maxAttempts else { return false }
    switch failureKind {
    case .connectionDropped: return true
    case .authOrSetupFail, .cleanExit: return false
    }
}
```

New:
```swift
public static func shouldReconnect(failureKind: FailureKind, attempt: Int) -> Bool {
    guard attempt <= maxAttempts else { return false }
    switch failureKind {
    case .connectionDropped: return true
    case .authOrSetupFail, .cleanExit, .networkUnreachable: return false
    }
}
```

Decision: `.networkUnreachable` does NOT auto-reconnect. It only fires from
`startConnection`'s preflight, before the ssh process exists — auto-retrying
a misconfigured host or a flaky DNS in tight loop is anti-social. The user
gets the FailureOverlay's manual Retry button instead.

Add a test for this in the same file we just created:

```swift
func testNetworkUnreachableDoesNotAutoReconnect() {
    XCTAssertFalse(ReconnectScheduler.shouldReconnect(
        failureKind: .networkUnreachable(.dnsFailed), attempt: 1))
}
```

- [ ] **Step 5: Run test to verify it passes**

```
cd apps/macos && swift test --filter SessionStoreTests.FailureKindTests
```

Expected: 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/SessionStore/FailureKind.swift \
        apps/macos/Sources/SessionStore/ReconnectScheduler.swift \
        apps/macos/Tests/SessionStoreTests/FailureKindTests.swift
git commit -m "feat(macos): add NetworkErrorReason + FailureKind.networkUnreachable"
```

---

## Task 2: Replace `.connecting` with `.preflight` and `.authenticating` in `ConnectionState`

**Files:**
- Modify: `apps/macos/Sources/SessionStore/ConnectionState.swift`
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift` (lines 214–215, 248)
- Modify: `apps/macos/Tests/SessionStoreTests/EndToEndSSHTests.swift:140`
- Modify: `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift:69` (the `markConnecting` call) — temporary: replace with `markAuthenticating` so the project still builds; final removal happens in Task 12

- [ ] **Step 1: Write a state-equality test**

Append to `apps/macos/Tests/SessionStoreTests/FailureKindTests.swift` (or create new file `ConnectionStateTests.swift` in the same target — easier):

Create `apps/macos/Tests/SessionStoreTests/ConnectionStateTests.swift`:

```swift
import XCTest
@testable import SessionStore

final class ConnectionStateTests: XCTestCase {
    func testStatesAreDistinct() {
        let now = Date()
        XCTAssertNotEqual(ConnectionState.idle, .preflight(startedAt: now))
        XCTAssertNotEqual(ConnectionState.preflight(startedAt: now),
                          .authenticating(startedAt: now))
        XCTAssertNotEqual(ConnectionState.authenticating(startedAt: now),
                          .connected(connectedAt: now))
    }

    func testEqualityRespectsAssociatedDate() {
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        XCTAssertEqual(ConnectionState.preflight(startedAt: t1),
                       ConnectionState.preflight(startedAt: t1))
        XCTAssertNotEqual(ConnectionState.preflight(startedAt: t1),
                          ConnectionState.preflight(startedAt: t2))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
cd apps/macos && swift test --filter SessionStoreTests.ConnectionStateTests
```

Expected: build error — `.preflight` and `.authenticating` are not defined.

- [ ] **Step 3: Replace `ConnectionState.swift`**

Replace contents of `apps/macos/Sources/SessionStore/ConnectionState.swift`:

```swift
import Foundation

public enum ConnectionState: Equatable {
    case idle
    /// TCP preflight in flight (NWConnection probing host:port).
    /// `surfaceGeneration` is NOT bumped here — the placeholder view stays.
    case preflight(startedAt: Date)
    /// ssh subprocess has been started; libghostty is driving it. Successor
    /// of the old `.connecting` case (semantically identical, renamed because
    /// "connecting" was ambiguous between TCP and SSH layers).
    case authenticating(startedAt: Date)
    case connected(connectedAt: Date)
    case reconnecting(attempt: Int, nextRetryAt: Date)
    case failed(FailureKind)
}
```

- [ ] **Step 4: Update `SessionStore.swift` call sites**

In `apps/macos/Sources/SessionStore/SessionStore.swift`, replace the existing `markConnecting`:

```swift
public func markConnecting(tabId: UUID) {
    update(tabId) { $0.state = .connecting(startedAt: Date()) }
}
```

with:

```swift
public func markAuthenticating(tabId: UUID) {
    update(tabId) { $0.state = .authenticating(startedAt: Date()) }
}
```

And update the `scheduleReconnect` body (around line 248):

Old:
```swift
self.update(tabId) { $0.surfaceGeneration += 1; $0.state = .connecting(startedAt: Date()) }
```

New (keeping the bump, just rename state):
```swift
self.update(tabId) { $0.surfaceGeneration += 1; $0.state = .authenticating(startedAt: Date()) }
```

(In Task 6 we'll route reconnect through `startConnection` for proper preflight; this commit is just the rename so the project still builds.)

- [ ] **Step 5: Update `TerminalContainerView.swift:69`**

In `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift`, change line 69:

Old: `store.markConnecting(tabId: tabId)`
New: `store.markAuthenticating(tabId: tabId)`

- [ ] **Step 6: Update `EndToEndSSHTests.swift:140`**

Same rename: `store.markConnecting(tabId: tabId)` → `store.markAuthenticating(tabId: tabId)`.

- [ ] **Step 7: Build + run all SessionStore tests**

```
cd apps/macos && swift test --filter SessionStoreTests
```

Expected: all green (the rename should be source-compatible for everything that doesn't pattern-match the state directly).

- [ ] **Step 8: Commit**

```bash
git add apps/macos/Sources/SessionStore/ConnectionState.swift \
        apps/macos/Sources/SessionStore/SessionStore.swift \
        apps/macos/Sources/Caterm/Views/TerminalContainerView.swift \
        apps/macos/Tests/SessionStoreTests/EndToEndSSHTests.swift \
        apps/macos/Tests/SessionStoreTests/ConnectionStateTests.swift
git commit -m "feat(macos): split ConnectionState into preflight + authenticating"
```

---

## Task 3: Define `PreflightProbing` protocol + `PreflightOutcome`

**Files:**
- Create: `apps/macos/Sources/SessionStore/PreflightProbing.swift`

This task introduces the protocol so other modules and tests can compile against it before the real `Preflight` implementation lands.

- [ ] **Step 1: Create `PreflightProbing.swift`**

Create `apps/macos/Sources/SessionStore/PreflightProbing.swift`:

```swift
import Foundation

/// Outcome of a TCP preflight probe. Independent of NWError so callers
/// don't need to import Network.framework.
public enum PreflightOutcome: Equatable {
    case ok
    case failed(NetworkErrorReason)
}

/// Abstraction over `Preflight.probe`. `SessionStore` consumes a value of
/// this protocol so tests can inject a fake without spinning up real
/// `NWConnection`s.
public protocol PreflightProbing: Sendable {
    func probe(host: String, port: UInt16, timeout: TimeInterval) async -> PreflightOutcome
}
```

- [ ] **Step 2: Verify compile**

```
cd apps/macos && swift build
```

Expected: build succeeds (no callers yet).

- [ ] **Step 3: Commit**

```bash
git add apps/macos/Sources/SessionStore/PreflightProbing.swift
git commit -m "feat(macos): introduce PreflightProbing protocol + PreflightOutcome"
```

---

## Task 4: Implement `Preflight` (NWConnection) + `mapNWError` unit test

**Files:**
- Create: `apps/macos/Sources/SessionStore/Preflight.swift`
- Create: `apps/macos/Tests/SessionStoreTests/PreflightTests.swift`

- [ ] **Step 1: Write tests for the NWError mapping helper**

Create `apps/macos/Tests/SessionStoreTests/PreflightTests.swift`:

```swift
import Network
import XCTest
@testable import SessionStore

final class PreflightTests: XCTestCase {

    // MARK: - mapNWError unit tests (pure, no networking)

    func testMapNWErrorECONNREFUSED() {
        let err = NWError.posix(.ECONNREFUSED)
        XCTAssertEqual(Preflight.mapNWError(err), .connectionRefused)
    }

    func testMapNWErrorETIMEDOUT() {
        let err = NWError.posix(.ETIMEDOUT)
        XCTAssertEqual(Preflight.mapNWError(err), .timedOut)
    }

    func testMapNWErrorENETDOWN() {
        XCTAssertEqual(Preflight.mapNWError(.posix(.ENETDOWN)), .networkDown)
        XCTAssertEqual(Preflight.mapNWError(.posix(.ENETUNREACH)), .networkDown)
        XCTAssertEqual(Preflight.mapNWError(.posix(.EHOSTUNREACH)), .networkDown)
    }

    func testMapNWErrorDNSGroupedAsDnsFailed() {
        // NWError.dns wraps a DNSServiceErrorType (Int32). NoSuchRecord = -65554.
        let err = NWError.dns(-65554)
        XCTAssertEqual(Preflight.mapNWError(err), .dnsFailed)
    }

    func testMapNWErrorOtherFallback() {
        // EPERM is unmapped — should land in .other.
        if case let .other(code, message) = Preflight.mapNWError(.posix(.EPERM)) {
            XCTAssertEqual(code, Int(POSIXErrorCode.EPERM.rawValue))
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("Expected .other for EPERM")
        }
    }

    // MARK: - Real NWConnection probe against a local listener

    func testProbeAgainstLocalListenerSucceeds() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
        }
        listener.start(queue: .global())
        defer { listener.cancel() }

        // Wait briefly for port assignment.
        let deadline = Date().addingTimeInterval(2)
        while listener.port == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let port = listener.port else {
            XCTFail("Listener never bound a port")
            return
        }

        let outcome = await Preflight().probe(host: "127.0.0.1",
                                              port: port.rawValue,
                                              timeout: 2)
        XCTAssertEqual(outcome, .ok)
    }

    func testProbeAgainstUnboundPortReturnsConnectionRefused() async {
        // Port 1 on 127.0.0.1 is essentially never listening on macOS.
        let outcome = await Preflight().probe(host: "127.0.0.1", port: 1, timeout: 2)
        XCTAssertEqual(outcome, .failed(.connectionRefused))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
cd apps/macos && swift test --filter SessionStoreTests.PreflightTests
```

Expected: build error — `Preflight` undefined.

- [ ] **Step 3: Create `Preflight.swift`**

Create `apps/macos/Sources/SessionStore/Preflight.swift`:

```swift
import Foundation
import Network

/// TCP preflight probe. Uses NWConnection to determine reachability and
/// classify failure type before the libghostty ssh subprocess is launched.
///
/// Threading: `probe` returns to the calling actor via a `CheckedContinuation`.
/// The internal `stateUpdateHandler` runs on `queue` (default
/// `DispatchQueue.global(qos: .userInitiated)`).
public struct Preflight: PreflightProbing {
    public init() {}

    public func probe(host: String, port: UInt16, timeout: TimeInterval = 5) async -> PreflightOutcome {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            // Should be unreachable: callers validate range before calling. Be
            // defensive anyway — `.other` is fine here since we never
            // construct an NWConnection.
            return .failed(.other(code: -1, message: "Port \(port) is invalid"))
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue.global(qos: .userInitiated)

        return await withCheckedContinuation { continuation in
            // Guard against double-resume from racing state callbacks vs timeout.
            let resumed = ResumedFlag()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.markIfFirst() {
                        connection.cancel()
                        continuation.resume(returning: .ok)
                    }
                case .failed(let error):
                    if resumed.markIfFirst() {
                        connection.cancel()
                        continuation.resume(returning: .failed(Self.mapNWError(error)))
                    }
                case .waiting(let error):
                    // .waiting fires when NWConnection cannot establish (e.g. no route,
                    // refused). Treat it as a terminal failure for our short-window probe.
                    if resumed.markIfFirst() {
                        connection.cancel()
                        continuation.resume(returning: .failed(Self.mapNWError(error)))
                    }
                case .cancelled, .preparing, .setup:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: queue)

            // Manual timeout — NWConnection's own .waiting may take long.
            queue.asyncAfter(deadline: .now() + timeout) {
                if resumed.markIfFirst() {
                    connection.cancel()
                    continuation.resume(returning: .failed(.timedOut))
                }
            }
        }
    }

    /// Maps an `NWError` to our typed `NetworkErrorReason`. Internal so unit
    /// tests can drive every branch without spinning up real connections.
    static func mapNWError(_ error: NWError) -> NetworkErrorReason {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .connectionRefused
            case .ETIMEDOUT:    return .timedOut
            case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH: return .networkDown
            default:
                return .other(code: Int(code.rawValue),
                              message: error.localizedDescription)
            }
        case .dns:
            return .dnsFailed
        case .tls:
            return .other(code: 0, message: error.localizedDescription)
        @unknown default:
            return .other(code: 0, message: error.localizedDescription)
        }
    }
}

/// Thread-safe one-shot flag. NWConnection state callbacks and the timeout
/// timer can both fire after one another resolved the continuation; this
/// ensures `continuation.resume` is called exactly once.
private final class ResumedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func markIfFirst() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
```

- [ ] **Step 4: Run tests**

```
cd apps/macos && swift test --filter SessionStoreTests.PreflightTests
```

Expected: 7 tests pass. The local-listener test may take 1–2 seconds; the unbound-port test should be near-instant.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SessionStore/Preflight.swift \
        apps/macos/Tests/SessionStoreTests/PreflightTests.swift
git commit -m "feat(macos): add Preflight TCP probe with NWError mapping"
```

---

## Task 5: Add `startConnection` + `retryTab` to `SessionStore`

**Files:**
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift` (init signature, new methods, attempt-token state)
- Test: `apps/macos/Tests/SessionStoreTests/SessionStoreConnectionFlowTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

Create `apps/macos/Tests/SessionStoreTests/SessionStoreConnectionFlowTests.swift`:

```swift
import XCTest
@testable import KeychainStore
@testable import SessionStore
@testable import SSHCommandBuilder

@MainActor
final class SessionStoreConnectionFlowTests: XCTestCase {

    private final class FakePreflight: PreflightProbing, @unchecked Sendable {
        var nextOutcome: PreflightOutcome = .ok
        var probeCount = 0
        var lastHost: String?
        var lastPort: UInt16?
        func probe(host: String, port: UInt16, timeout: TimeInterval) async -> PreflightOutcome {
            probeCount += 1
            lastHost = host
            lastPort = port
            return nextOutcome
        }
    }

    private func makeStore(preflight: PreflightProbing = FakePreflight()) -> SessionStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-conn-\(UUID()).json")
        let kc = KeychainStore(service: "com.caterm.test.\(UUID())", accessGroup: nil)
        return SessionStore(askpassPath: "/dev/null",
                            knownHostsCaterm: "/dev/null",
                            knownHostsUser: "/dev/null",
                            accessGroup: nil,
                            hostsURL: tmp,
                            keychain: kc,
                            preflight: preflight)
    }

    private func makeHost(port: Int = 22) -> SSHHost {
        SSHHost(name: "h", hostname: "192.0.2.1", port: port,
                username: "u", credential: .password)
    }

    /// Task 5 tests call `startConnection` EXPLICITLY (not relying on
    /// openTab to wire it — that wiring lands in Task 6). After Task 6,
    /// openTab will also fire its own startConnection; the attempt-token
    /// guard means the explicit call always wins. State-based assertions
    /// (rather than counting probes) keep these tests robust across both
    /// orderings.

    func testStartConnectionSuccessFlow() async {
        let fake = FakePreflight()
        fake.nextOutcome = .ok
        let store = makeStore(preflight: fake)
        let id = store.openTab(host: makeHost())
        store.startConnection(tabId: id)
        await store.awaitConnectionAttempt(tabId: id)
        guard let tab = store.tabs.first(where: { $0.id == id }) else {
            return XCTFail("tab missing")
        }
        if case .authenticating = tab.state { /* ok */ } else {
            XCTFail("expected .authenticating, got \(tab.state)")
        }
        XCTAssertGreaterThanOrEqual(tab.surfaceGeneration, 1,
            "should bump at least once on a successful auth transition")
    }

    func testStartConnectionDnsFailureFlow() async {
        let fake = FakePreflight()
        fake.nextOutcome = .failed(.dnsFailed)
        let store = makeStore(preflight: fake)
        let id = store.openTab(host: makeHost())
        store.startConnection(tabId: id)
        await store.awaitConnectionAttempt(tabId: id)
        guard let tab = store.tabs.first(where: { $0.id == id }) else {
            return XCTFail("tab missing")
        }
        XCTAssertEqual(tab.state, .failed(.networkUnreachable(.dnsFailed)))
        XCTAssertEqual(tab.surfaceGeneration, 0,
            "no .ok outcome means no gen bump (placeholder must stay)")
    }

    func testStartConnectionInvalidPortBypassesProbe() async {
        let fake = FakePreflight()
        let store = makeStore(preflight: fake)
        let id = store.openTab(host: makeHost(port: 99999))
        store.startConnection(tabId: id)
        await store.awaitConnectionAttempt(tabId: id)
        guard let tab = store.tabs.first(where: { $0.id == id }) else {
            return XCTFail("tab missing")
        }
        XCTAssertEqual(tab.state, .failed(.networkUnreachable(.invalidPort(99999))))
        XCTAssertEqual(fake.probeCount, 0,
            "out-of-range port must skip probe in EVERY attempt")
    }

    func testRetryTabResetsStateAndStartsAgain() async {
        let fake = FakePreflight()
        fake.nextOutcome = .failed(.timedOut)
        let store = makeStore(preflight: fake)
        let id = store.openTab(host: makeHost())
        store.startConnection(tabId: id)
        await store.awaitConnectionAttempt(tabId: id)
        XCTAssertEqual(store.tabs.first?.state,
                       .failed(.networkUnreachable(.timedOut)))

        fake.nextOutcome = .ok
        store.retryTab(tabId: id)
        await store.awaitConnectionAttempt(tabId: id)
        guard let tab = store.tabs.first(where: { $0.id == id }) else {
            return XCTFail("tab missing")
        }
        if case .authenticating = tab.state { /* ok */ } else {
            XCTFail("retry should reach .authenticating, got \(tab.state)")
        }
    }

    func testStaleProbeOutcomeDoesNotMutateTabState() async {
        // GatedPreflight parks every probe in a continuations array so the
        // test can resolve them in any order.
        final class GatedPreflight: PreflightProbing, @unchecked Sendable {
            let lock = NSLock()
            var continuations: [CheckedContinuation<PreflightOutcome, Never>] = []
            func probe(host: String, port: UInt16, timeout: TimeInterval) async -> PreflightOutcome {
                await withCheckedContinuation { c in
                    lock.lock(); continuations.append(c); lock.unlock()
                }
            }
            func count() -> Int {
                lock.lock(); defer { lock.unlock() }
                return continuations.count
            }
        }
        let gated = GatedPreflight()
        let store = makeStore(preflight: gated)
        let id = store.openTab(host: makeHost())
        store.startConnection(tabId: id)  // attempt 1 — token=1
        store.startConnection(tabId: id)  // attempt 2 — token=2 (supersedes)

        // Wait until both probes are parked.
        let deadline = Date().addingTimeInterval(2)
        while gated.count() < 2, Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(gated.count(), 2, "both probes should be in flight")

        // Resolve STALE (token=1) probe first with .ok — must NOT mutate state
        // away from .preflight, because token check fails.
        gated.continuations[0].resume(returning: .ok)
        await Task.yield(); await Task.yield()
        if case .authenticating = store.tabs.first?.state {
            XCTFail("stale .ok must not transition to .authenticating")
        }

        // Resolve CURRENT (token=2) probe with failure — should mutate.
        gated.continuations[1].resume(returning: .failed(.dnsFailed))
        await Task.yield(); await Task.yield()
        XCTAssertEqual(store.tabs.first?.state,
                       .failed(.networkUnreachable(.dnsFailed)),
                       "only the latest attempt's outcome should win")
    }
}
```

> Note: `awaitConnectionAttempt(tabId:)` is a test-only helper we'll add to `SessionStore` in Step 3. It awaits the in-flight `startConnection` Task for a given tab.

- [ ] **Step 2: Run to verify failure**

```
cd apps/macos && swift test --filter SessionStoreTests.SessionStoreConnectionFlowTests
```

Expected: build errors — `preflight` init parameter, `startConnection`, `retryTab`, `awaitConnectionAttempt` don't exist.

- [ ] **Step 3: Modify `SessionStore.swift`**

In `apps/macos/Sources/SessionStore/SessionStore.swift`:

a. Add the new stored properties at the top of the class (right after `private var teardownWorkItems`):

```swift
private let preflight: PreflightProbing

/// Per-tab attempt token — bumped on every `startConnection` invocation
/// so a stale async probe outcome from a cancelled retry cannot mutate
/// the current tab state.
private var connectionAttempts: [UUID: UInt64] = [:]

/// In-flight `startConnection` Tasks per tab. Tests use
/// `awaitConnectionAttempt(tabId:)` to await them deterministically.
private var pendingStartTasks: [UUID: Task<Void, Never>] = [:]
```

b. Update the `init` signature:

```swift
public init(askpassPath: String, knownHostsCaterm: String,
            knownHostsUser: String, accessGroup: String?,
            hostsURL: URL, keychain: KeychainStore,
            controlMasterManager: ControlMasterTearDowning? = nil,
            preflight: PreflightProbing = Preflight()) {
    self.askpassPath = askpassPath
    self.knownHostsCaterm = knownHostsCaterm
    self.knownHostsUser = knownHostsUser
    self.accessGroup = accessGroup
    self.hostsURL = hostsURL
    self.keychain = keychain
    self.controlMasterManager = controlMasterManager
    self.preflight = preflight
    do {
        self.hosts = try HostPersistence.load(from: hostsURL)
    } catch {
        self.hosts = []
    }
}
```

c. Append the new methods near the existing `markAuthenticating` (replacing the deprecated body — `markAuthenticating` stays as a tiny wrapper for the few internal call sites):

```swift
/// Single entry point for "kick off connection for this tab". Idempotent:
/// callers (`openTab`, `retryTab`, reconnect timer) can all invoke; the
/// attempt token guards stale results.
public func startConnection(tabId: UUID) {
    let task = Task { @MainActor [weak self] in
        await self?.runConnection(tabId: tabId)
    }
    pendingStartTasks[tabId] = task
}

private func runConnection(tabId: UUID) async {
    guard let host = tabs.first(where: { $0.id == tabId })?.host else { return }
    let token = (connectionAttempts[tabId] ?? 0) &+ 1
    connectionAttempts[tabId] = token

    guard (1...65535).contains(host.port) else {
        applyIfCurrent(tabId: tabId, token: token) { tab in
            tab.state = .failed(.networkUnreachable(.invalidPort(host.port)))
        }
        return
    }

    applyIfCurrent(tabId: tabId, token: token) { tab in
        tab.state = .preflight(startedAt: Date())
    }

    let outcome = await preflight.probe(
        host: host.hostname,
        port: UInt16(host.port),
        timeout: 5
    )

    applyIfCurrent(tabId: tabId, token: token) { tab in
        switch outcome {
        case .ok:
            tab.surfaceGeneration += 1
            tab.state = .authenticating(startedAt: Date())
        case .failed(let reason):
            tab.state = .failed(.networkUnreachable(reason))
        }
    }
}

private func applyIfCurrent(tabId: UUID, token: UInt64,
                            _ mutate: (inout Tab) -> Void) {
    guard connectionAttempts[tabId] == token else { return }
    update(tabId, mutate)
}

public func retryTab(tabId: UUID) {
    update(tabId) {
        $0.lastFailure = nil
        $0.state = .idle
    }
    startConnection(tabId: tabId)
}

/// Test-only: await the most recent in-flight `startConnection` Task.
/// Marked public so XCTest can call it; production code never needs to.
public func awaitConnectionAttempt(tabId: UUID) async {
    if let t = pendingStartTasks[tabId] {
        await t.value
    }
}
```

(Keep the existing `markAuthenticating` method from Task 2 — it's still called from `TerminalContainerView.swift` until Task 12 / 13 remove that call.)

- [ ] **Step 4: Run flow tests**

```
cd apps/macos && swift test --filter SessionStoreTests.SessionStoreConnectionFlowTests
```

Expected: 5 tests pass.

- [ ] **Step 5: Run full SessionStore tests**

```
cd apps/macos && swift test --filter SessionStoreTests
```

Expected: all green (no regressions).

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/SessionStore/SessionStore.swift \
        apps/macos/Tests/SessionStoreTests/SessionStoreConnectionFlowTests.swift
git commit -m "feat(macos): add SessionStore.startConnection with attempt token"
```

---

## Task 6: Wire `openTab` and reconnect timer to fire `startConnection`

**Files:**
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift` (the existing `openTab` and `scheduleReconnect`)

- [ ] **Step 1: Write a test asserting `openTab` triggers connection**

Append to `apps/macos/Tests/SessionStoreTests/SessionStoreConnectionFlowTests.swift`:

```swift
func testOpenTabFiresStartConnection() async {
    let fake = FakePreflight()
    fake.nextOutcome = .ok
    let store = makeStore(preflight: fake)
    _ = store.openTab(host: makeHost())
    XCTAssertEqual(store.tabs.count, 1)
    // openTab should kick off probe — wait for it.
    await store.awaitConnectionAttempt(tabId: store.tabs[0].id)
    XCTAssertEqual(fake.probeCount, 1)
}

func testReconnectTimerGoesThroughPreflight() async {
    // Force the FSM into .reconnecting by calling markChildExited from a
    // .connected state on a tab that already had hadConnected=true.
    let fake = FakePreflight()
    fake.nextOutcome = .ok
    let store = makeStore(preflight: fake)
    let id = store.openTab(host: makeHost())
    await store.awaitConnectionAttempt(tabId: id)
    store.markConnected(tabId: id)

    // Make backoff very small for test purposes by overriding through
    // ReconnectScheduler — but the FSM uses fixed backoff. We instead
    // assert that the scheduled reconnect path uses startConnection,
    // i.e., the FakePreflight gets a second probe call within ~5s.
    store.markChildExited(tabId: id, exitCode: 1) // -> .reconnecting

    // First reconnect attempt has backoff ~1s (see ReconnectScheduler).
    let deadline = Date().addingTimeInterval(6)
    while fake.probeCount < 2, Date() < deadline {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertGreaterThanOrEqual(fake.probeCount, 2,
        "scheduleReconnect should route through startConnection")
}
```

- [ ] **Step 2: Run tests**

```
cd apps/macos && swift test --filter SessionStoreTests.SessionStoreConnectionFlowTests
```

Expected: `testOpenTabFiresStartConnection` and `testReconnectTimerGoesThroughPreflight` fail (`probeCount` stays 0 / 1).

- [ ] **Step 3: Modify `openTab`**

In `apps/macos/Sources/SessionStore/SessionStore.swift`, find `public func openTab(host: SSHHost) -> UUID` (around line 140) and append a `startConnection` call before returning:

```swift
public func openTab(host: SSHHost) -> UUID {
    teardownWorkItems[host.id]?.cancel()
    teardownWorkItems.removeValue(forKey: host.id)
    let destination = "\(host.username)@\(host.hostname)"
    controlMasterManager?.register(hostId: host.id, destination: destination)
    let tab = Tab(host: host)
    tabs.append(tab)
    startConnection(tabId: tab.id)            // ← NEW
    return tab.id
}
```

- [ ] **Step 4: Modify `scheduleReconnect`**

Replace the body of `scheduleReconnect` (around line 244–250):

Old:
```swift
private func scheduleReconnect(tabId: UUID, after seconds: TimeInterval) {
    Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard let self else { return }
        self.update(tabId) { $0.surfaceGeneration += 1; $0.state = .authenticating(startedAt: Date()) }
    }
}
```

New:
```swift
private func scheduleReconnect(tabId: UUID, after seconds: TimeInterval) {
    Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard let self else { return }
        // Route through startConnection so the reconnect attempt also gets
        // TCP preflight + typed networkUnreachable failure if the network
        // is still down. surfaceGeneration is bumped inside startConnection
        // when probe succeeds.
        self.startConnection(tabId: tabId)
    }
}
```

- [ ] **Step 5: Run tests**

```
cd apps/macos && swift test --filter SessionStoreTests
```

Expected: all green, including the two new tests.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/SessionStore/SessionStore.swift \
        apps/macos/Tests/SessionStoreTests/SessionStoreConnectionFlowTests.swift
git commit -m "feat(macos): route openTab and reconnect timer through startConnection"
```

---

## Task 7: Tighten `HostFormView` port validation to 1–65535

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/HostFormView.swift:144–149`

- [ ] **Step 1: Write the change**

Replace the `isValid` getter:

Old:
```swift
private var isValid: Bool {
    !hostname.isEmpty
        && !username.isEmpty
        && (credKind != .keyFile || !keyPath.isEmpty)
        && Int(port) != nil
}
```

New:
```swift
private var isValid: Bool {
    !hostname.isEmpty
        && !username.isEmpty
        && (credKind != .keyFile || !keyPath.isEmpty)
        && (Int(port).map { (1...65535).contains($0) } ?? false)
}
```

- [ ] **Step 2: Build to verify it compiles**

```
cd apps/macos && swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/HostFormView.swift
git commit -m "fix(macos): clamp HostFormView port input to 1...65535"
```

---

## Task 8: Create `FailurePresentation` helper + tests

**Files:**
- Create: `apps/macos/Sources/Caterm/Views/FailurePresentation.swift`
- Create: `apps/macos/Tests/CatermTests/FailurePresentationTests.swift`

- [ ] **Step 1: Write the failing test**

Create `apps/macos/Tests/CatermTests/FailurePresentationTests.swift`:

```swift
import XCTest
@testable import Caterm
@testable import SessionStore
@testable import SSHCommandBuilder

final class FailurePresentationTests: XCTestCase {
    private func host(port: Int = 22) -> SSHHost {
        SSHHost(name: "h", hostname: "example.com", port: port,
                username: "u", credential: .password)
    }

    func testDnsFailedTitleAndDetailUseHostname() {
        let p = FailurePresentation.from(failure: .networkUnreachable(.dnsFailed),
                                         host: host())
        XCTAssertEqual(p.icon, .orange)
        XCTAssertEqual(p.title, "Host not found")
        XCTAssertTrue(p.detail?.contains("example.com") ?? false)
    }

    func testConnectionRefusedMentionsPort() {
        let p = FailurePresentation.from(failure: .networkUnreachable(.connectionRefused),
                                         host: host(port: 2222))
        XCTAssertEqual(p.title, "Connection refused")
        XCTAssertTrue(p.detail?.contains("2222") ?? false)
    }

    func testTimedOutMentionsHostAndPort() {
        let p = FailurePresentation.from(failure: .networkUnreachable(.timedOut),
                                         host: host(port: 22))
        XCTAssertEqual(p.title, "Connection timed out")
        XCTAssertTrue(p.detail?.contains("example.com") ?? false)
        XCTAssertTrue(p.detail?.contains("22") ?? false)
    }

    func testInvalidPortIsRedAndShowsValue() {
        let p = FailurePresentation.from(failure: .networkUnreachable(.invalidPort(99999)),
                                         host: host(port: 99999))
        XCTAssertEqual(p.icon, .red)
        XCTAssertEqual(p.title, "Invalid port")
        XCTAssertTrue(p.detail?.contains("99999") ?? false)
    }

    func testAuthFail() {
        let p = FailurePresentation.from(failure: .authOrSetupFail, host: host())
        XCTAssertEqual(p.icon, .red)
        XCTAssertEqual(p.title, "Authentication failed")
    }
}
```

- [ ] **Step 2: Run the test to verify failure**

```
cd apps/macos && swift test --filter CatermTests.FailurePresentationTests
```

Expected: build error — `FailurePresentation` does not exist.

- [ ] **Step 3: Create `FailurePresentation.swift`**

Create `apps/macos/Sources/Caterm/Views/FailurePresentation.swift`:

```swift
import SessionStore
import SSHCommandBuilder
import SwiftUI

public enum FailureIcon: Equatable {
    case red
    case orange
}

/// View-model for `FailureOverlay`. Maps a `FailureKind` + the host being
/// connected to a presentation triple (icon color, short title, optional
/// detail line). Pure function; no SwiftUI state.
public struct FailurePresentation: Equatable {
    public var icon: FailureIcon
    public var title: String
    public var detail: String?

    public static func from(failure: FailureKind, host: SSHHost) -> FailurePresentation {
        switch failure {
        case .networkUnreachable(.dnsFailed):
            return .init(icon: .orange,
                         title: "Host not found",
                         detail: "Could not resolve hostname \(host.hostname)")
        case .networkUnreachable(.connectionRefused):
            return .init(icon: .orange,
                         title: "Connection refused",
                         detail: "Port \(host.port) is not accepting connections")
        case .networkUnreachable(.timedOut):
            return .init(icon: .orange,
                         title: "Connection timed out",
                         detail: "No response from \(host.hostname):\(host.port) after 5 seconds")
        case .networkUnreachable(.networkDown):
            return .init(icon: .orange,
                         title: "No network",
                         detail: "Check your internet connection")
        case .networkUnreachable(.invalidPort(let p)):
            return .init(icon: .red,
                         title: "Invalid port",
                         detail: "Port \(p) is out of range (1–65535) — edit host to fix")
        case .networkUnreachable(.other(_, let message)):
            return .init(icon: .orange,
                         title: "Connection failed",
                         detail: message)
        case .authOrSetupFail:
            return .init(icon: .red,
                         title: "Authentication failed",
                         detail: "Permission denied — check credentials")
        case .cleanExit, .connectionDropped:
            // Caller filters these out before presenting; keep a defensive
            // empty value to avoid a crash if the filter is bypassed.
            return .init(icon: .orange, title: "", detail: nil)
        }
    }
}
```

- [ ] **Step 4: Run test**

```
cd apps/macos && swift test --filter CatermTests.FailurePresentationTests
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/FailurePresentation.swift \
        apps/macos/Tests/CatermTests/FailurePresentationTests.swift
git commit -m "feat(macos): add FailurePresentation view-model helper"
```

---

## Task 9: Create `ConnectingOverlay` view

**Files:**
- Create: `apps/macos/Sources/Caterm/Views/ConnectingOverlay.swift`

This is a SwiftUI view; we don't unit-test the visuals (no snapshot framework — see spec Non-Goals). Manual checklist (Task 14) covers it.

- [ ] **Step 1: Create `ConnectingOverlay.swift`**

Create `apps/macos/Sources/Caterm/Views/ConnectingOverlay.swift`:

```swift
import SSHCommandBuilder
import SwiftUI

public enum ConnectingStage: Equatable {
    case preflight
    case authenticating

    var label: String {
        switch self {
        case .preflight:      return "Connecting…"
        case .authenticating: return "Authenticating…"
        }
    }
}

/// Termius-style centered overlay shown during the success path of an
/// initial connect (or a retry). Not used for `.reconnecting` — that is
/// `ReconnectOverlay`'s job (it has the countdown semantics).
struct ConnectingOverlay: View {
    let stage: ConnectingStage
    let host: SSHHost
    let startedAt: Date

    @State private var now = Date()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var elapsed: TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.78).ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.regular)
                Text(stage.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                hostLine
                if elapsed >= 2 {
                    Text(String(format: "elapsed %.0fs", elapsed))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 28)
        }
        .onReceive(timer) { now = $0 }
        .transition(.opacity)
    }

    private var hostLine: some View {
        HStack(spacing: 0) {
            Text(host.username).foregroundColor(Color(red: 0.47, green: 0.76, blue: 1.0))   // soft blue
            Text("@").foregroundColor(.gray)
            Text(host.hostname).foregroundColor(Color(red: 0.82, green: 0.66, blue: 1.0))   // soft purple
            Text(":\(host.port)").foregroundColor(.gray)
        }
        .font(.system(size: 13, design: .monospaced))
    }
}
```

- [ ] **Step 2: Build**

```
cd apps/macos && swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/ConnectingOverlay.swift
git commit -m "feat(macos): add ConnectingOverlay (Termius-style success path)"
```

---

## Task 10: Create `FailureOverlay` view + Edit Host notification name

**Files:**
- Create: `apps/macos/Sources/Caterm/Views/FailureOverlay.swift`
- Create: `apps/macos/Sources/Caterm/Views/EditHostNotification.swift`

- [ ] **Step 1: Create `EditHostNotification.swift`**

Create `apps/macos/Sources/Caterm/Views/EditHostNotification.swift`:

```swift
import Foundation

public extension Notification.Name {
    /// Posted by `FailureOverlay`'s "Edit Host" button. `HostListSidebar`
    /// observes this and pops the existing edit sheet for the host. Same
    /// pattern as `catermHostCredentialMaterialChanged` in SessionStore.
    static let catermEditHostRequested = Notification.Name("catermEditHostRequested")
}

public enum CatermEditHostRequestedKeys {
    /// `UUID` — local host id whose form should be opened.
    public static let hostId = "hostId"
}
```

- [ ] **Step 2: Create `FailureOverlay.swift`**

Create `apps/macos/Sources/Caterm/Views/FailureOverlay.swift`:

```swift
import SessionStore
import SSHCommandBuilder
import SwiftUI

/// Overlay shown when a connection attempt fails (preflight failure or
/// `.authOrSetupFail`). Stays visible until the user clicks Retry / Edit
/// Host or closes the tab.
struct FailureOverlay: View {
    let failure: FailureKind
    let host: SSHHost
    let onRetry: () -> Void
    let onEditHost: () -> Void

    private var presentation: FailurePresentation {
        FailurePresentation.from(failure: failure, host: host)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.78).ignoresSafeArea()
            VStack(spacing: 10) {
                icon
                Text(presentation.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                hostLine
                if let detail = presentation.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: 360)
                }
                actions.padding(.top, 4)
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 28)
        }
    }

    private var icon: some View {
        let bg: Color = (presentation.icon == .red) ? .red : .orange
        return ZStack {
            Circle().fill(bg)
            Text("!").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
        }
        .frame(width: 22, height: 22)
    }

    private var hostLine: some View {
        HStack(spacing: 0) {
            Text(host.username).foregroundColor(Color(red: 0.47, green: 0.76, blue: 1.0))
            Text("@").foregroundColor(.gray)
            Text(host.hostname).foregroundColor(Color(red: 0.82, green: 0.66, blue: 1.0))
        }
        .font(.system(size: 13, design: .monospaced))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Retry", action: onRetry).buttonStyle(.borderedProminent)
            Button("Edit Host", action: onEditHost).buttonStyle(.bordered)
        }
    }
}
```

- [ ] **Step 3: Build**

```
cd apps/macos && swift build
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/FailureOverlay.swift \
        apps/macos/Sources/Caterm/Views/EditHostNotification.swift
git commit -m "feat(macos): add FailureOverlay + Edit Host notification"
```

---

## Task 11: Wire `HostListSidebar` to listen for Edit Host notifications

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/HostListSidebar.swift` (add `.onReceive` modifier on the outer VStack/List)

- [ ] **Step 1: Modify `HostListSidebar.swift`**

Find the `.sheet(item: $editingHost)` modifier (line 94) and append a new `.onReceive` modifier after the closing brace of the sheet:

```swift
.onReceive(NotificationCenter.default.publisher(for: .catermEditHostRequested)) { note in
    guard let hostId = note.userInfo?[CatermEditHostRequestedKeys.hostId] as? UUID,
          let host = store.hosts.first(where: { $0.id == hostId }) else {
        return
    }
    editingHost = host
}
```

(Insert it at the same indentation level as `.sheet(item: $editingHost)`. The exact placement: after the `}` that closes the sheet's content closure but still chained on the same `List` view.)

- [ ] **Step 2: Build**

```
cd apps/macos && swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/HostListSidebar.swift
git commit -m "feat(macos): observe catermEditHostRequested in HostListSidebar"
```

---

## Task 12: Rewrite `TerminalContainerView` with state-driven surface + overlay routing

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift`

⚠️ **Critical constraint** (spec §4.5): never instantiate `GhosttySurfaceNSView` while the tab is in `.idle | .preflight | .failed` — `command: nil` would fall back to `$SHELL` and fork a local shell.

- [ ] **Step 1: Replace the `TerminalContainerView` struct**

Replace the existing `TerminalContainerView` struct (lines 13–37) with:

```swift
struct TerminalContainerView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var surfaceRegistry: SurfaceRegistry
    let tabId: UUID

    private var backgroundTransparencyEnabled: Bool {
        (settingsStore.settings.global.windowOpacity ?? 1.0) < 0.999
    }

    var body: some View {
        ZStack {
            if let tab = store.tabs.first(where: { $0.id == tabId }) {
                surfaceOrPlaceholder(for: tab)
                overlay(for: tab.state, host: tab.host)
            }
        }
        .animation(.easeOut(duration: 0.15),
                   value: store.tabs.first(where: { $0.id == tabId })?.state)
    }

    @ViewBuilder
    private func surfaceOrPlaceholder(for tab: SessionStore.Tab) -> some View {
        switch tab.state {
        case .authenticating, .connected, .reconnecting:
            TerminalSurfaceRepresentable(
                tabId: tabId,
                backgroundTransparencyEnabled: backgroundTransparencyEnabled
            )
            .id("\(tabId)-\(tab.surfaceGeneration)")

        case .idle, .preflight, .failed:
            // Inert SwiftUI background — no NSView, no $SHELL fork.
            Color.black.opacity(0.95).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func overlay(for state: ConnectionState, host: SSHHost) -> some View {
        switch state {
        case .preflight(let startedAt):
            ConnectingOverlay(stage: .preflight, host: host, startedAt: startedAt)
        case .authenticating(let startedAt):
            ConnectingOverlay(stage: .authenticating, host: host, startedAt: startedAt)
        case .reconnecting(let attempt, let nextRetryAt):
            ReconnectOverlay(attempt: attempt, nextRetryAt: nextRetryAt)
        case .failed(let kind) where shouldShowFailureOverlay(kind):
            FailureOverlay(
                failure: kind,
                host: host,
                onRetry: { store.retryTab(tabId: tabId) },
                onEditHost: {
                    NotificationCenter.default.post(
                        name: .catermEditHostRequested,
                        object: nil,
                        userInfo: [CatermEditHostRequestedKeys.hostId: host.id]
                    )
                }
            )
        case .idle, .connected, .failed:
            EmptyView()
        }
    }

    private func shouldShowFailureOverlay(_ kind: FailureKind) -> Bool {
        switch kind {
        case .cleanExit, .connectionDropped: return false
        case .authOrSetupFail, .networkUnreachable: return true
        }
    }
}
```

- [ ] **Step 2: Build**

```
cd apps/macos && swift build
```

Expected: build succeeds. (`TerminalSurfaceRepresentable` is below in the same file and still has the old body — Task 13 cleans it up.)

- [ ] **Step 3: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/TerminalContainerView.swift
git commit -m "feat(macos): state-driven placeholder + overlay routing in TerminalContainerView"
```

---

## Task 13: Strip stale `markAuthenticating` from `TerminalSurfaceRepresentable`

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift` (the `TerminalSurfaceRepresentable` at lines 51–100)
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift` (remove `markAuthenticating`)
- Modify: `apps/macos/Tests/SessionStoreTests/EndToEndSSHTests.swift:140` (remove the call — no replacement needed)

`TerminalSurfaceRepresentable.makeNSView` was previously responsible for transitioning the tab to `.authenticating`. Now `SessionStore.startConnection` owns that transition and the surface is only ever created when state is already `.authenticating`. Calling `markAuthenticating` from the view would re-mutate state for no reason and could race with the attempt token logic.

- [ ] **Step 1: Edit `TerminalSurfaceRepresentable.makeNSView`**

In `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift`, find:

```swift
let view = GhosttySurfaceNSView(command: cfg.command, env: cfg.env)
view.setBackgroundTransparencyEnabled(backgroundTransparencyEnabled)
store.markAuthenticating(tabId: tabId)
```

Remove the `store.markAuthenticating(tabId: tabId)` line.

The 3-second `markConnected` Task at the bottom stays as-is — it's an independent grace window for "ssh subprocess didn't crash within 3s of being forked", which complements (not duplicates) the preflight.

- [ ] **Step 2: Remove `markAuthenticating` from SessionStore**

In `apps/macos/Sources/SessionStore/SessionStore.swift`, delete:

```swift
public func markAuthenticating(tabId: UUID) {
    update(tabId) { $0.state = .authenticating(startedAt: Date()) }
}
```

- [ ] **Step 3: Update `EndToEndSSHTests.swift`**

Open `apps/macos/Tests/SessionStoreTests/EndToEndSSHTests.swift` and find the line that calls `store.markAuthenticating(tabId: tabId)` (line 140 originally). Replace with the new entry point:

Old:
```swift
store.markAuthenticating(tabId: tabId)
```

New:
```swift
store.startConnection(tabId: tabId)
await store.awaitConnectionAttempt(tabId: tabId)
```

(If the test method is not already `async`, mark it `async` and propagate to its `XCTestCase` declaration.)

- [ ] **Step 4: Run full test suite**

```
cd apps/macos && swift test
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/TerminalContainerView.swift \
        apps/macos/Sources/SessionStore/SessionStore.swift \
        apps/macos/Tests/SessionStoreTests/EndToEndSSHTests.swift
git commit -m "refactor(macos): strip markAuthenticating from view; SessionStore owns transitions"
```

---

## Task 14: Manual verification checklist

**Files:**
- Create: `apps/macos/Manual/connection-progress-checklist.md`

- [ ] **Step 1: Create the checklist**

Create `apps/macos/Manual/connection-progress-checklist.md`:

```markdown
# Connection Progress UI — Manual Verification

Run after any change to `SessionStore.startConnection`, `Preflight`,
`ConnectingOverlay`, `FailureOverlay`, or `TerminalContainerView`.

Build + launch:

```
cd apps/macos && make run-app
```

For each scenario below, observe the overlay state, then either let it
resolve or click Retry / Edit Host as instructed.

## 1. Happy path — fast LAN host
- Add a host on your LAN that you can reach instantly.
- Connect.
- **Expect:** brief flash of `Connecting…` (< 500ms), then `Authenticating…`,
  then overlay fades out within ~150ms. No `elapsed` line should show.

## 2. Slow connect — VPN or remote host
- Connect to a host across a VPN or another continent.
- **Expect:** `Connecting…` shown ≥ 1s; once elapsed ≥ 2s, the
  `elapsed Ns` line appears. Stage transitions to `Authenticating…` once
  TCP completes. Overlay fades out on success.

## 3. DNS failure
- Add a host with hostname `caterm-no-such-host-xyz.invalid` port 22.
- Connect.
- **Expect:** within ~5s, overlay turns to FailureOverlay:
  - Orange `!` icon
  - Title "Host not found"
  - Detail "Could not resolve hostname caterm-no-such-host-xyz.invalid"
  - Retry / Edit Host buttons.

## 4. Connection refused
- Add a host with `hostname=127.0.0.1`, `port=2`. Connect.
- **Expect:** overlay shows "Connection refused" within ~1s,
  detail "Port 2 is not accepting connections".

## 5. Connection timed out
- Add a host with `hostname=192.0.2.1` (TEST-NET-1), `port=22`. Connect.
- **Expect:** overlay shows "Connection timed out" after ~5s, detail
  references `192.0.2.1:22`. (TEST-NET-1 is reserved for examples and
  black-holes packets.)

## 6. Authentication failure
- Add a real reachable host but provide a wrong password / key.
- Connect.
- **Expect:** overlay transitions through `Connecting…` → `Authenticating…`,
  ssh subprocess exits, FailureOverlay shows "Authentication failed",
  red `!` icon, Retry / Edit Host buttons.

## 7. Retry button
- After any failure overlay appears, click Retry.
- **Expect:** overlay returns to `Connecting…` and the flow re-runs.

## 8. Edit Host button
- After a failure overlay, click Edit Host.
- **Expect:** the existing host edit sheet opens with the failed host
  pre-populated. Cancel returns to the failure overlay.

## 9. Invalid port (legacy data)
- Manually edit `~/Library/Application Support/Caterm/.../hosts.json`
  to set a host's `port` to `99999`. Restart the app.
- Connect to that host.
- **Expect:** overlay immediately shows "Invalid port" (red icon), detail
  "Port 99999 is out of range (1–65535) — edit host to fix".

## 10. Reconnect path unchanged
- Connect successfully. Disconnect the network mid-session.
- **Expect:** existing `ReconnectOverlay` (with countdown) still renders.
  Once the timer fires, the new flow activates: `Connecting…` overlay
  appears (preflight). If still offline, "No network" failure shown.
- Reconnect the network; let auto-reconnect succeed.

## 11. Concurrent retries don't race
- Trigger a failure, click Retry rapidly multiple times within 1s.
- **Expect:** only the latest attempt's outcome lands in the overlay.
  No flicker between "auth-success" surfaces from stale attempts.
```

- [ ] **Step 2: Commit**

```bash
git add apps/macos/Manual/connection-progress-checklist.md
git commit -m "docs(macos): manual checklist for connection progress UI"
```

---

## Task 15: Final lint, build, and full test run

- [ ] **Step 1: Lint / format**

```
bun x ultracite check
```

Expected: no output (or only pre-existing warnings unrelated to this work).

If anything was changed in JS/TS files (this plan should not have touched any), run:

```
bun x ultracite fix
```

- [ ] **Step 2: Full Swift test run**

```
cd apps/macos && swift test
```

Expected: all green. The Preflight tests use real `NWConnection`s but only against `127.0.0.1`, so they should be deterministic in any sandbox.

- [ ] **Step 3: Build the app bundle**

```
cd apps/macos && make run-app
```

Run scenarios 1–3 from the manual checklist (happy path + DNS fail + connection refused) as a smoke test.

- [ ] **Step 4: Final commit (if any cleanup)**

If `ultracite fix` or other auto-formatters touched anything:

```bash
git add -A
git commit -m "chore(macos): formatter pass after connection progress work"
```

---

## Done

The feature is complete when:

- ✅ `swift test` is green for all targets (especially `SessionStoreTests` and `CatermTests`)
- ✅ All scenarios in `apps/macos/Manual/connection-progress-checklist.md` verified
- ✅ The 4 mockup states from the spec render correctly: Connecting / Authenticating / Auth Failed / Network Failed
- ✅ Reconnect flow continues to work (Task 14 §10)
