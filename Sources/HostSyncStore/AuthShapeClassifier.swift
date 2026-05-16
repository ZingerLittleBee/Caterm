import ServerSyncClient

/// Returns true if the given `ServerSyncError` is the "401 / unauthenticated"
/// shape that should classify as `SyncErrorKind.auth`.
///
/// Single source of truth — both the store's `classifySyncError` and the
/// view layer's `accountState` go through here. New auth-shape cases (e.g.
/// a future server-side `.tokenExpired` code) are added here once.
///
/// Takes `ServerSyncError` (not `Error`) because:
/// - The view-layer call site has a typed `ServerSyncError?`
///   (per `SyncSettingsView.accountState(... lastSyncError:)`).
/// - The store's `classifySyncError(_ error: Error)` does the
///   `error as? ServerSyncError` cast at the call site, then calls this
///   function. Non-ServerSyncError types (URLError, etc.) are inherently
///   `.other` and never reach this function (spec Decision #25).
public func isAuthShape(_ error: ServerSyncError) -> Bool {
    switch error {
    case .http(status: 401, _),
         .orpc(_, status: 401, _),
         .authFailed,
         .notSignedIn:
        return true
    default:
        return false
    }
}
