import XCTest
@testable import HostSyncStore

final class SyncFailureStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let threshold: TimeInterval = 15 * 60

    func testNormal_whenNeverSyncedAndNoAttempt() {
        let state = syncFailureState(
            now: now,
            lastSyncedAt: nil,
            lastSyncAttemptedAt: nil,
            lastSyncErrorKind: nil,
            periodicSyncEnabled: true,
            failingThreshold: threshold
        )
        XCTAssertEqual(
            state,
            .normal,
            "Fresh-install user with no attempt yet is .normal — no error to report"
        )
    }

    /// Regression for first-time-failure visibility (pre-merge review #3):
    /// a freshly-signed-in user whose first sync errors out must not render
    /// as healthy. Before the fix, this returned `.normal` because
    /// `lastSyncedAt == nil` short-circuited the function.
    func testFailing_whenNeverSyncedButAttemptedWithOtherError() {
        let attempted = now.addingTimeInterval(-30 * 60)
        let state = syncFailureState(
            now: now,
            lastSyncedAt: nil,
            lastSyncAttemptedAt: attempted,
            lastSyncErrorKind: .other,
            periodicSyncEnabled: true,
            failingThreshold: threshold
        )
        XCTAssertEqual(
            state,
            .failing(reason: .other, since: attempted),
            "Never-synced user with a recorded error must surface as .failing, not Never synced"
        )
    }

    /// 401 on first sync (cookie present, server expired): user must see
    /// "Sign in again" affordance rather than "Never synced".
    func testFailing_whenNeverSyncedButAttemptedWithAuthError() {
        let attempted = now.addingTimeInterval(-30 * 60)
        let state = syncFailureState(
            now: now,
            lastSyncedAt: nil,
            lastSyncAttemptedAt: attempted,
            lastSyncErrorKind: .auth,
            periodicSyncEnabled: true,
            failingThreshold: threshold
        )
        XCTAssertEqual(
            state,
            .failing(reason: .auth, since: attempted),
            "Never-synced user with an auth error must route to sign-in recovery"
        )
    }

    /// Boundary: attempted but no error classified yet (e.g., sync still
    /// in flight or the classifier hasn't run). Don't fabricate a failure.
    func testNormal_whenNeverSyncedAttemptedButNoErrorKind() {
        let state = syncFailureState(
            now: now,
            lastSyncedAt: nil,
            lastSyncAttemptedAt: now.addingTimeInterval(-30 * 60),
            lastSyncErrorKind: nil,
            periodicSyncEnabled: true,
            failingThreshold: threshold
        )
        XCTAssertEqual(
            state,
            .normal,
            "Without a classified error there's nothing to surface — stay .normal"
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
