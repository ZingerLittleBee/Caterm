import XCTest
@testable import HostSyncStore

final class SyncIndicatorStateTests: XCTestCase {
    private let now = Date()
    private let interval: TimeInterval = 15 * 60  // 15 min, matches periodicInterval default

    private func farPast(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(-seconds)
    }

    // MARK: - Priority order: signedOut > syncing > failing > healthy

    func testSignedOutMasksAllOtherSignals() {
        let state = syncIndicatorState(
            now: now,
            isSignedIn: false,
            isSyncing: true,
            lastSyncedAt: farPast(60),
            lastSyncAttemptedAt: farPast(30),
            lastSyncErrorKind: .other,
            failingSince: farPast(2000),
            periodicSyncEnabled: true,
            failingThreshold: interval
        )
        XCTAssertEqual(state, .signedOut,
            "isSignedIn=false must short-circuit even when other signals look unhealthy (priority 1)")
    }

    func testSyncingMasksFailing() {
        let state = syncIndicatorState(
            now: now,
            isSignedIn: true,
            isSyncing: true,
            lastSyncedAt: farPast(2000),         // older than threshold
            lastSyncAttemptedAt: farPast(30),
            lastSyncErrorKind: .other,
            failingSince: farPast(2000),
            periodicSyncEnabled: true,
            failingThreshold: interval
        )
        XCTAssertEqual(state, .syncing,
            "isSyncing must override failing (priority 2 over priority 3)")
    }

    func testFailingMasksHealthy() {
        let attempted = farPast(60)
        let state = syncIndicatorState(
            now: now,
            isSignedIn: true,
            isSyncing: false,
            lastSyncedAt: farPast(2000),         // > threshold
            lastSyncAttemptedAt: attempted,
            lastSyncErrorKind: .other,
            failingSince: nil,                    // exercise attemptedSince fallback
            periodicSyncEnabled: true,
            failingThreshold: interval
        )
        XCTAssertEqual(state, .failing(reason: .other, since: attempted),
            "Failing state takes the attempted timestamp when failingSince is nil")
    }

    func testFailingAuthShape() {
        let firstFailed = farPast(2000)
        let state = syncIndicatorState(
            now: now,
            isSignedIn: true,
            isSyncing: false,
            lastSyncedAt: farPast(2000),
            lastSyncAttemptedAt: farPast(30),
            lastSyncErrorKind: .auth,
            failingSince: firstFailed,
            periodicSyncEnabled: true,
            failingThreshold: interval
        )
        XCTAssertEqual(state, .failing(reason: .auth, since: firstFailed),
            "lastSyncErrorKind=.auth produces a failing case with reason: .auth")
    }

    // MARK: - Healthy

    func testHealthyWithLastSyncedAt() {
        let last = farPast(60)
        let state = syncIndicatorState(
            now: now,
            isSignedIn: true,
            isSyncing: false,
            lastSyncedAt: last,
            lastSyncAttemptedAt: last,
            lastSyncErrorKind: nil,
            failingSince: nil,
            periodicSyncEnabled: true,
            failingThreshold: interval
        )
        XCTAssertEqual(state, .healthy(lastSyncedAt: last))
    }

    func testHealthyWithNilLastSyncedAt() {
        let state = syncIndicatorState(
            now: now,
            isSignedIn: true,
            isSyncing: false,
            lastSyncedAt: nil,
            lastSyncAttemptedAt: nil,
            lastSyncErrorKind: nil,
            failingSince: nil,
            periodicSyncEnabled: true,
            failingThreshold: interval
        )
        XCTAssertEqual(state, .healthy(lastSyncedAt: nil),
            "Fresh signed-in user with no completed sync renders 'Never synced'")
    }

    // MARK: - failingSince stability across retries (Decision #21)

    func testFailingSinceIsStableAcrossRetries() {
        let firstFailed = farPast(2000)        // T0 — first failure of this run
        let mostRecent = farPast(30)           // T1 — most recent retry attempt
        let state = syncIndicatorState(
            now: now,
            isSignedIn: true,
            isSyncing: false,
            lastSyncedAt: farPast(2000),
            lastSyncAttemptedAt: mostRecent,
            lastSyncErrorKind: .other,
            failingSince: firstFailed,
            periodicSyncEnabled: true,
            failingThreshold: interval
        )
        XCTAssertEqual(state, .failing(reason: .other, since: firstFailed),
            "failingSince (first failure) must be preferred over lastSyncAttemptedAt " +
            "(most recent retry). Without this, retry cycles would advance the visible " +
            "'stuck N min' timestamp (spec Decision #21).")
    }
}
