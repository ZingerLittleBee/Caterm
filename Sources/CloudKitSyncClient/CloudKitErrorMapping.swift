import CloudKit
import Foundation
import ServerSyncClient

public enum CloudKitErrorMapping {
    /// Maps any error thrown out of CloudKit calls into the
    /// `ServerSyncError` shape that `HostSyncStore.classifySyncError` and
    /// `isAuthShape(_:)` already understand.
    ///
    /// - `.notAuthenticated` → `.notSignedIn` (HostSyncStore treats this
    ///   as auth-failure → flips `lastSyncErrorKind = .auth`).
    /// - `.serverRecordChanged` → synthetic HTTP 409. The next
    ///   reconcile pass uses LWW on `updatedAt` to resolve.
    /// - everything else → `.http(status: 0, ...)` (HostSyncStore
    ///   treats this as `.other`).
    public static func map(_ error: Error) -> ServerSyncError {
        guard let ck = error as? CKError else {
            return .http(status: 0, body: error.localizedDescription)
        }
        switch ck.code {
        case .notAuthenticated:
            return .notSignedIn
        case .serverRecordChanged:
            return .http(status: 409, body: ck.localizedDescription)
        default:
            return .http(status: 0, body: ck.localizedDescription)
        }
    }
}
