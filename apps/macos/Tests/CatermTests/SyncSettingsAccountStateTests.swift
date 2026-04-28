import XCTest
@testable import Caterm
@testable import ServerSyncClient

final class SyncSettingsAccountStateTests: XCTestCase {
    func testAccountStateSignedOut() {
        XCTAssertEqual(accountState(isSignedIn: false, lastSyncError: nil),
                       .signedOut)
    }

    func testAccountStateSignedIn() {
        XCTAssertEqual(accountState(isSignedIn: true, lastSyncError: nil),
                       .signedIn)
    }

    func testAccountStateSessionExpired401Http() {
        XCTAssertEqual(
            accountState(isSignedIn: true,
                         lastSyncError: .http(status: 401, body: "")),
            .sessionExpired)
    }

    func testAccountStateSessionExpired401Orpc() {
        XCTAssertEqual(
            accountState(isSignedIn: true,
                         lastSyncError: .orpc(code: "UNAUTHORIZED",
                                              status: 401,
                                              message: "Unauthorized")),
            .sessionExpired,
            "oRPC route returns 401 wrapped in .orpc, not .http — see ServerSyncClientHTTPTests:58")
    }

    func testAccountStateSessionExpiredAuthFailed() {
        XCTAssertEqual(
            accountState(isSignedIn: true,
                         lastSyncError: .authFailed(code: "x", message: "y")),
            .sessionExpired)
    }

    func testAccountStateNon401HttpError() {
        XCTAssertEqual(
            accountState(isSignedIn: true,
                         lastSyncError: .http(status: 500, body: "")),
            .signedIn,
            "5xx is not an auth failure — Account remains 'Sign Out'")
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
