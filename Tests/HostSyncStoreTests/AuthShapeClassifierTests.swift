import XCTest
import ServerSyncClient
@testable import HostSyncStore

final class AuthShapeClassifierTests: XCTestCase {
    func testHttp401IsAuthShape() {
        XCTAssertTrue(isAuthShape(.http(status: 401, body: "")),
            "401 over plain HTTP is the standard auth shape")
    }

    func testORPC401IsAuthShape() {
        XCTAssertTrue(isAuthShape(.orpc(code: "UNAUTHORIZED",
                                         status: 401,
                                         message: "session expired")),
            "oRPC envelope wraps 401 — must classify as auth shape")
    }

    func testAuthFailedIsAuthShape() {
        XCTAssertTrue(isAuthShape(.authFailed(code: "INVALID_PASSWORD",
                                                message: "wrong password")),
            "better-auth typed error path is auth shape")
    }

    func testNotSignedInIsAuthShape() {
        XCTAssertTrue(isAuthShape(.notSignedIn),
            "Pre-flight 'no cookie' is auth shape")
    }

    func testNon401IsNotAuthShape() {
        XCTAssertFalse(isAuthShape(.http(status: 500, body: "")),
            "500 is .other, not .auth")
        XCTAssertFalse(isAuthShape(.orpc(code: "INTERNAL",
                                          status: 500,
                                          message: "")),
            "Non-401 oRPC is .other, not .auth")
        XCTAssertFalse(isAuthShape(.decode("malformed json")),
            "Decode failures are .other")
    }
}
