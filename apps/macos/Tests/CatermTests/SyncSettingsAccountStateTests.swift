import XCTest
@testable import Caterm
@testable import HostSyncStore
@testable import ServerSyncClient

final class SyncSettingsAccountStateTests: XCTestCase {
    func testAccountStateSignedOut() {
        XCTAssertEqual(accountState(isSignedIn: false, lastSyncError: nil, lastSyncErrorKind: nil),
                       .signedOut)
    }

    func testAccountStateSignedOutTakesPriorityOverStaleAuthError() {
        XCTAssertEqual(
            accountState(isSignedIn: false,
                         lastSyncError: nil,
                         lastSyncErrorKind: .auth),
            .signedOut,
            "Signed-out users should see the plain Sign In action even if stale auth state exists")
    }

    func testAccountStateSignedIn() {
        XCTAssertEqual(accountState(isSignedIn: true, lastSyncError: nil, lastSyncErrorKind: nil),
                       .signedIn)
    }

    func testAccountStateSessionExpired401Http() {
        XCTAssertEqual(
            accountState(isSignedIn: true,
                         lastSyncError: .http(status: 401, body: ""),
                         lastSyncErrorKind: nil),
            .sessionExpired)
    }

    func testAccountStateSessionExpired401Orpc() {
        XCTAssertEqual(
            accountState(isSignedIn: true,
                         lastSyncError: .orpc(code: "UNAUTHORIZED",
                                              status: 401,
                                              message: "Unauthorized"),
                         lastSyncErrorKind: nil),
            .sessionExpired,
            "oRPC route returns 401 wrapped in .orpc, not .http — see ServerSyncClientHTTPTests:58")
    }

    func testAccountStateSessionExpiredAuthFailed() {
        XCTAssertEqual(
            accountState(isSignedIn: true,
                         lastSyncError: .authFailed(code: "x", message: "y"),
                         lastSyncErrorKind: nil),
            .sessionExpired)
    }

    func testAccountStateNon401HttpError() {
        XCTAssertEqual(
            accountState(isSignedIn: true,
                         lastSyncError: .http(status: 500, body: ""),
                         lastSyncErrorKind: nil),
            .signedIn,
            "5xx is not an auth failure — Account remains 'Sign Out'")
    }

    func testAccountState_returnsSessionExpired_whenStoreErrorKindAuth_evenWithNilLastSyncError() {
        let state = accountState(isSignedIn: true,
                                 lastSyncError: nil,
                                 lastSyncErrorKind: .auth)
        XCTAssertEqual(state, .sessionExpired,
            "Auto-only 401 must surface as .sessionExpired CTA — auth-priority invariant")
    }

    func testFailureDetailsOnlyShowWhenSignedIn() {
        XCTAssertTrue(shouldShowSyncFailureDetails(for: .signedIn))
        XCTAssertFalse(shouldShowSyncFailureDetails(for: .signedOut))
        XCTAssertFalse(shouldShowSyncFailureDetails(for: .sessionExpired))
    }

    // MARK: - formatLastSyncedAt (spec §3.3 / §7.5)

    func testFormattedLastSyncedAtNeverWhenNil() {
        XCTAssertEqual(formatLastSyncedAt(nil), "Never synced")
    }

    func testFormattedLastSyncedAtRelative() {
        // 2 minutes ago — RelativeDateTimeFormatter should produce a
        // non-empty, locale-dependent phrase. We don't pin specific
        // wording (en-US "2 minutes ago" vs zh-CN "2分钟前"), only that
        // it's not the "Never synced" sentinel.
        let twoMinutesAgo = Date().addingTimeInterval(-120)
        let result = formatLastSyncedAt(twoMinutesAgo)
        XCTAssertFalse(result.isEmpty,
            "Relative format must produce non-empty output")
        XCTAssertNotEqual(result, "Never synced",
            "Non-nil date must produce relative phrase, not the nil sentinel")
    }
}
