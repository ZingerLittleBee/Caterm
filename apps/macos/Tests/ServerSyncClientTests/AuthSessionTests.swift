import XCTest
@testable import ServerSyncClient

final class AuthSessionTests: XCTestCase {
    var session: AuthSession!
    var urlSession: URLSession!

    override func setUp() {
        MockURLProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        cfg.httpShouldSetCookies = true
        urlSession = URLSession(configuration: cfg)
        session = AuthSession(
            baseURL: URL(string: "https://api.example.com")!,
            session: urlSession
        )
    }

    func testSignInPostsToCorrectEndpoint() async throws {
        MockURLProtocol.handler = { _ in
            let resp = HTTPURLResponse(
                url: URL(string: "https://api.example.com/api/auth/sign-in/email")!,
                statusCode: 200, httpVersion: nil,
                headerFields: ["Set-Cookie": "better-auth.session_token=abc; Path=/; HttpOnly"]
            )!
            return (resp, Data(#"{"user":{"id":"u1","email":"a@b.com"}}"#.utf8))
        }
        try await session.signIn(email: "a@b.com", password: "secret")
        let req = MockURLProtocol.capturedRequests[0]
        XCTAssertEqual(req.url?.path, "/api/auth/sign-in/email")
        XCTAssertEqual(req.httpMethod, "POST")
        let body = String(data: MockURLProtocol.capturedBodies[0], encoding: .utf8)!
        XCTAssertTrue(body.contains("\"email\":\"a@b.com\""))
        XCTAssertTrue(body.contains("\"password\":\"secret\""))
    }

    func testSignInThrowsOnInvalidCredentials() async {
        MockURLProtocol.handler = { _ in
            let resp = HTTPURLResponse(
                url: URL(string: "https://api.example.com/api/auth/sign-in/email")!,
                statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"""
            {"message":"Invalid email or password","code":"INVALID_EMAIL_OR_PASSWORD"}
            """#.utf8))
        }
        do {
            try await session.signIn(email: "x@y.com", password: "wrong")
            XCTFail("expected throw")
        } catch let ServerSyncError.authFailed(code, _) {
            XCTAssertEqual(code, "INVALID_EMAIL_OR_PASSWORD")
        } catch { XCTFail("wrong: \(error)") }
    }

    func testIsSignedInReflectsCookiePresence() async throws {
        XCTAssertFalse(session.isSignedIn)
        // Inject a session cookie directly
        let cookie = HTTPCookie(properties: [
            .name: "better-auth.session_token",
            .value: "abc",
            .path: "/",
            .domain: "api.example.com"
        ])!
        urlSession.configuration.httpCookieStorage?.setCookie(cookie)
        XCTAssertTrue(session.isSignedIn)
    }

    func testSignOutClearsCookie() async throws {
        let cookie = HTTPCookie(properties: [
            .name: "better-auth.session_token",
            .value: "abc",
            .path: "/",
            .domain: "api.example.com"
        ])!
        urlSession.configuration.httpCookieStorage?.setCookie(cookie)

        MockURLProtocol.handler = { _ in
            let resp = HTTPURLResponse(
                url: URL(string: "https://api.example.com/api/auth/sign-out")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("{}".utf8))
        }
        try await session.signOut()
        XCTAssertFalse(session.isSignedIn)
    }
}
