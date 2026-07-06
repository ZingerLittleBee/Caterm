import XCTest
@testable import KeychainStore
@testable import SessionStore
@testable import SSHCommandBuilder

/// Integration tests for the FSM logic inside `SessionStore.markChildExited`.
/// All state mutations are synchronous; the `Task.sleep` in `scheduleReconnect`
/// is never awaited, so these tests remain deterministic and instant.
@MainActor
final class SessionStoreFSMTests: XCTestCase {
    var sut: SessionStore!
    var tmpHostsURL: URL!

    override func setUp() async throws {
        tmpHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-fsm-\(UUID().uuidString).json")
        let kc = KeychainStore(service: "com.caterm.test.\(UUID().uuidString)", accessGroup: nil)
        sut = SessionStore(
            askpassPath: "/dev/null", knownHostsCaterm: "/dev/null",
            knownHostsUser: "/dev/null", accessGroup: nil,
            hostsURL: tmpHostsURL, keychain: kc
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpHostsURL)
    }

    // MARK: - Helpers

    private func makeHost() -> SSHHost {
        SSHHost(name: "h", hostname: "127.0.0.1", port: 22,
                username: "u", credential: .password)
    }

    private func tab(id: UUID) -> SessionStore.Tab? {
        sut.tabs.first(where: { $0.id == id })
    }

    // MARK: - Tests

    /// A drop (exit 255) after `markConnected` enters `.reconnecting(attempt: 1)`.
    func testMarkChildExitedDroppedConnectionEntersReconnecting() {
        let tabId = sut.openTab(host: makeHost())
        sut.markConnected(tabId: tabId)

        sut.markChildExited(tabId: tabId, exitCode: 255)

        guard let t = tab(id: tabId) else {
            XCTFail("tab missing"); return
        }
        if case let .reconnecting(attempt, _) = t.state {
            XCTAssertEqual(attempt, 1)
        } else {
            XCTFail("expected .reconnecting, got \(t.state)")
        }
        XCTAssertEqual(t.reconnectAttempts, 1)
    }

    /// Repeated drops correctly increment the attempt counter.
    func testReconnectAttemptsIncrement() {
        let tabId = sut.openTab(host: makeHost())
        sut.markConnected(tabId: tabId)

        // Drive 4 drops; each call increments reconnectAttempts by 1.
        for _ in 1...4 {
            sut.markChildExited(tabId: tabId, exitCode: 255)
        }

        guard let t = tab(id: tabId) else {
            XCTFail("tab missing"); return
        }
        if case let .reconnecting(attempt, _) = t.state {
            XCTAssertEqual(attempt, 4)
        } else {
            XCTFail("expected .reconnecting, got \(t.state)")
        }
        XCTAssertEqual(t.reconnectAttempts, 4)
    }

    /// After `maxAttempts` drops the next drop transitions to `.failed(.connectionDropped)`.
    func testGivesUpAfterMaxAttempts() {
        let tabId = sut.openTab(host: makeHost())
        sut.markConnected(tabId: tabId)

        // Exhaust all allowed reconnect attempts.
        for _ in 1...ReconnectScheduler.maxAttempts {
            sut.markChildExited(tabId: tabId, exitCode: 255)
        }

        // One more drop should exceed maxAttempts.
        sut.markChildExited(tabId: tabId, exitCode: 255)

        guard let t = tab(id: tabId) else {
            XCTFail("tab missing"); return
        }
        if case let .failed(kind) = t.state {
            XCTAssertEqual(kind, .connectionDropped)
        } else {
            XCTFail("expected .failed(.connectionDropped), got \(t.state)")
        }
    }

    /// `markConnected` resets `reconnectAttempts` to 0.
    func testMarkConnectedResetsAttempts() {
        let tabId = sut.openTab(host: makeHost())
        sut.markConnected(tabId: tabId)

        // Simulate a couple of drops.
        sut.markChildExited(tabId: tabId, exitCode: 255)
        sut.markChildExited(tabId: tabId, exitCode: 255)

        guard let before = tab(id: tabId) else { XCTFail("tab missing"); return }
        XCTAssertEqual(before.reconnectAttempts, 2)

        // A successful reconnect resets the counter.
        sut.markConnected(tabId: tabId)

        guard let after = tab(id: tabId) else { XCTFail("tab missing"); return }
        XCTAssertEqual(after.reconnectAttempts, 0)
    }

    // MARK: - markConnectedProvisional

    /// Provisional connect dismisses the overlay (enters `.connected`) but does
    /// NOT commit `hadConnected` — so a later exit still classifies by failure.
    func testProvisionalEntersConnectedWithoutCommittingHadConnected() {
        let tabId = sut.openTab(host: makeHost())
        sut.markConnectedProvisional(tabId: tabId)

        guard let t = tab(id: tabId) else { XCTFail("tab missing"); return }
        guard case .connected = t.state else {
            XCTFail("expected .connected, got \(t.state)"); return
        }
        XCTAssertFalse(t.hadConnected,
                       "provisional connect must not commit hadConnected")
    }

    /// A *slow* auth/setup failure — process exits after a provisional connect
    /// but before the confirming `markConnected` — must still classify as
    /// `.authOrSetupFail` (never a reconnectable `.connectionDropped`), because
    /// `hadConnected` was never committed.
    func testProvisionalThenExitClassifiesAsAuthFail() {
        let tabId = sut.openTab(host: makeHost())
        sut.markConnectedProvisional(tabId: tabId)

        sut.markChildExited(tabId: tabId, exitCode: 255)

        guard let t = tab(id: tabId) else { XCTFail("tab missing"); return }
        if case let .failed(kind) = t.state {
            XCTAssertEqual(kind, .authOrSetupFail)
        } else {
            XCTFail("expected .failed(.authOrSetupFail), got \(t.state)")
        }
    }

    /// Provisional is a no-op once the tab has truly connected: it must not
    /// clobber a committed `hadConnected` (which would misclassify a later drop).
    func testProvisionalIsNoOpAfterRealConnect() {
        let tabId = sut.openTab(host: makeHost())
        sut.markConnected(tabId: tabId)

        sut.markConnectedProvisional(tabId: tabId)

        guard let t = tab(id: tabId) else { XCTFail("tab missing"); return }
        XCTAssertTrue(t.hadConnected,
                      "provisional must not un-commit a real connection")

        // A subsequent drop after a real connect still reconnects.
        sut.markChildExited(tabId: tabId, exitCode: 255)
        guard let after = tab(id: tabId) else { XCTFail("tab missing"); return }
        if case .reconnecting = after.state {} else {
            XCTFail("expected .reconnecting, got \(after.state)")
        }
    }
}
