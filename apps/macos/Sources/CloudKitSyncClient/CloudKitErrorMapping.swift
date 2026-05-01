import CloudKit
import Foundation
import ServerSyncClient

public enum CloudKitErrorMapping {
    public static func map(_ error: Error) -> ServerSyncError {
        if let ck = error as? CKError, ck.code == .notAuthenticated {
            return .notSignedIn
        }
        return .http(status: 0, body: error.localizedDescription)
    }
}
