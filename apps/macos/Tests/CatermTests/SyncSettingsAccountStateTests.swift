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
}
