import Foundation

/// User-facing state of the sidebar sync indicator. Derived from a snapshot
/// of the store + auth session at body-evaluation time.
///
/// Priority order (highest first): signedOut > syncing > failing > healthy.
public enum SyncIndicatorState: Equatable, Sendable {
    case signedOut
    case syncing
    /// Mirrors `SyncFailureState.failing` payload. Includes auth shape so
    /// the view can route `.auth` taps to the settings sheet directly.
    case failing(reason: SyncErrorKind, since: Date)
    /// `lastSyncedAt` may be nil for a freshly-signed-in user that has not
    /// yet completed a sync — the row shows "Never synced".
    case healthy(lastSyncedAt: Date?)
}

/// Pure derivation. Tested without any SwiftUI harness.
///
/// Priority: signedOut > syncing > failing > healthy. The store's
/// `failingSince` may be set during a sync, but while `isSyncing` is true
/// the indicator shows `.syncing` — when the in-flight sync resolves, the
/// store will either clear `failingSince` (recovery) or keep it (still
/// broken), and the next render reflects that.
///
/// `failingSince` parameter (preferred over `syncFailureState`'s
/// `attemptedSince` for the `.failing` payload): without this carve-out,
/// retry-failed cycles would advance the user-visible "stuck N min"
/// because `lastSyncAttemptedAt` updates per attempt while `failingSince`
/// stays anchored at the first failure of the run (spec Decision #21).
public func syncIndicatorState(
    now: Date,
    isSignedIn: Bool,
    isSyncing: Bool,
    lastSyncedAt: Date?,
    lastSyncAttemptedAt: Date?,
    lastSyncErrorKind: SyncErrorKind?,
    failingSince: Date?,
    periodicSyncEnabled: Bool,
    failingThreshold: TimeInterval
) -> SyncIndicatorState {
    if !isSignedIn { return .signedOut }
    if isSyncing { return .syncing }
    let failure = syncFailureState(
        now: now,
        lastSyncedAt: lastSyncedAt,
        lastSyncAttemptedAt: lastSyncAttemptedAt,
        lastSyncErrorKind: lastSyncErrorKind,
        periodicSyncEnabled: periodicSyncEnabled,
        failingThreshold: failingThreshold
    )
    switch failure {
    case .normal:
        return .healthy(lastSyncedAt: lastSyncedAt)
    case .failing(let reason, let attemptedSince):
        let stableSince = failingSince ?? attemptedSince
        return .failing(reason: reason, since: stableSince)
    }
}

// MARK: - Tap routing

/// What clicking the sidebar sync row should do. Lifted out of the view as
/// a pure function so tap routing is unit-tested without a SwiftUI harness
/// (spec Decision #26).
public enum SyncStatusTapAction: Equatable, Sendable {
    /// Posts `.catermOpenSyncSettings`. Used for `.signedOut` and
    /// `.failing(reason: .auth, ...)` — both have a single useful action
    /// (sign in). A popover with one button is worse UX than direct sheet.
    case openSettings
    /// Toggles the row's `@State popoverPresented`. Used for `.healthy`,
    /// `.failing(reason: .other, ...)`, and `.syncing`.
    case togglePopover
}

public func tapAction(for state: SyncIndicatorState) -> SyncStatusTapAction {
    switch state {
    case .signedOut,
         .failing(reason: .auth, since: _):
        return .openSettings
    case .healthy,
         .failing(reason: .other, since: _),
         .syncing:
        return .togglePopover
    }
}
