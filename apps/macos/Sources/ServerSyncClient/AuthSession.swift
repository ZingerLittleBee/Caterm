import Foundation

/// Email/password sign-in against better-auth. Session is a HTTP cookie
/// (`better-auth.session_token`) stored in the URLSession's cookie jar.
/// Persistence across app launches comes from using
/// `HTTPCookieStorage.shared` (the URLSession default) — no Keychain
/// involvement for the session token.
public final class AuthSession {
    private let baseURL: URL
    private let session: URLSession
    private let cookieName = "better-auth.session_token"

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public var isSignedIn: Bool {
        let store = session.configuration.httpCookieStorage ?? .shared
        return store.cookies(for: baseURL)?.contains { $0.name == cookieName } ?? false
    }

    public func signIn(email: String, password: String) async throws {
        struct Input: Codable { let email: String; let password: String }
        struct AuthError: Codable { let code: String; let message: String }

        var req = URLRequest(url: baseURL.appendingPathComponent("/api/auth/sign-in/email"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Input(email: email, password: password))

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ServerSyncError.http(status: 0, body: "no http response")
        }
        if !(200..<300).contains(http.statusCode) {
            if let err = try? JSONDecoder().decode(AuthError.self, from: data) {
                throw ServerSyncError.authFailed(code: err.code, message: err.message)
            }
            throw ServerSyncError.http(status: http.statusCode,
                                       body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    public func signOut() async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/auth/sign-out"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Best-effort server call; even if it fails we clear cookies locally.
        _ = try? await session.data(for: req)
        let store = session.configuration.httpCookieStorage ?? .shared
        store.cookies(for: baseURL)?.forEach { store.deleteCookie($0) }
    }
}
