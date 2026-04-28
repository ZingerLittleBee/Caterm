import Foundation

public enum ServerSyncError: Error, Equatable, CustomStringConvertible {
    /// Server returned an oRPC-shaped error envelope.
    case orpc(code: String, status: Int, message: String)
    /// HTTP transport error (non-2xx, non-oRPC error body, network failure).
    case http(status: Int, body: String)
    /// Auth flow failed (better-auth error response).
    case authFailed(code: String, message: String)
    /// User isn't signed in (no session cookie).
    case notSignedIn
    /// Decoding the response body failed.
    case decode(String)

    public var description: String {
        switch self {
        case let .orpc(code, status, msg):  return "oRPC \(code) (\(status)): \(msg)"
        case let .http(status, body):        return "HTTP \(status): \(body)"
        case let .authFailed(code, msg):    return "Auth \(code): \(msg)"
        case .notSignedIn:                   return "Not signed in"
        case let .decode(msg):              return "Decode failure: \(msg)"
        }
    }
}
