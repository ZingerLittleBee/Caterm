import XCTest
@testable import HostSyncStore

final class SyncFailureStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let threshold: TimeInterval = 15 * 60

    func testNormal_whenLastSyncedAtIsNil() {
        let state = syncFailureState(
            now: now,
            lastSyncedAt: nil,
            lastSyncAttemptedAt: now.addingTimeInterval(-30 * 60),
            lastSyncErrorKind: .other,
            periodicSyncEnabled: true,
            failingThreshold: threshold
        )
        XCTAssertEqual(
            state,
            .normal,
            "Fresh-install user (never had a successful sync) is .normal, not .failing"
        )
    }

    func testNormal_whenAttemptedNotAfterSucceeded() {
        let succeeded = now.addingTimeInterval(-10 * 60)
        let state = syncFailureState(
            now: now,
            lastSyncedAt: succeeded,
            lastSyncAttemptedAt: succeeded,
            lastSyncErrorKind: nil,
            periodicSyncEnabled: true,
            failingThreshold: threshold
        )
        XCTAssertEqual(
            state,
            .normal,
            "attempted == succeeded ⇒ last attempt landed cleanly; .normal"
        )
    }

    func testNormal_whenWithinThreshold() {
        let succeeded = now.addingTimeInterval(-5 * 60)
        let attempted = now.addingTimeInterval(-1 * 60)
        let state = syncFailureState(
            now: now,
            lastSyncedAt: succeeded,
            lastSyncAttemptedAt: attempted,
            lastSyncErrorKind: .other,
            periodicSyncEnabled: true,
            failingThreshold: threshold
        )
        XCTAssertEqual(
            state,
            .normal,
            "Within threshold ⇒ failure not yet user-visible (avoid flicker on a single transient blip)"
        )
    }

    func testFailing_whenAttemptedAfterSucceededAndPastThreshold() {
        let succeeded = now.addingTimeInterval(-30 * 60)
        let attempted = now.addingTimeInterval(-1 * 60)
        let state = syncFailureState(
            now: now,
            lastSyncedAt: succeeded,
            lastSyncAttemptedAt: attempted,
            lastSyncErrorKind: .auth,
            periodicSyncEnabled: true,
            failingThreshold: threshold
        )
        XCTAssertEqual(
            state,
            .failing(reason: .auth, since: attempted),
            "attempted > succeeded AND now - succeeded > threshold ⇒ .failing with attempted as `since`"
        )
    }

    func testNormal_whenPeriodicSyncDisabled() {
        let succeeded = now.addingTimeInterval(-30 * 60)
        let attempted = now.addingTimeInterval(-1 * 60)
        let state = syncFailureState(
            now: now,
            lastSyncedAt: succeeded,
            lastSyncAttemptedAt: attempted,
            lastSyncErrorKind: .other,
            periodicSyncEnabled: false,
            failingThreshold: threshold
        )
        XCTAssertEqual(
            state,
            .normal,
            "User-paused sync should not nag; spec §1 invariant"
        )
    }
}
