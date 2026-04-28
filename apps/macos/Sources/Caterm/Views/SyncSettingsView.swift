import HostSyncStore
import ServerSyncClient
import SwiftUI

/// Tri-state derivation for the Account section. Internal so CatermTests
/// can reach it via `@testable import Caterm`.
enum AccountState: Equatable {
    case signedOut
    case signedIn
    /// Signed in locally (cookie present), but the server has expired the
    /// session. Surfaces as "Sign In Again…" so the user doesn't have to
    /// Sign Out and Sign In as two separate steps.
    case sessionExpired
}

/// Pure derivation — no SwiftUI state. Tested directly in
/// `SyncSettingsAccountStateTests` without any view harness.
func accountState(isSignedIn: Bool,
                  lastSyncError: ServerSyncError?) -> AccountState {
    if isAuthFailure(lastSyncError) { return .sessionExpired }
    return isSignedIn ? .signedIn : .signedOut
}

private func isAuthFailure(_ err: ServerSyncError?) -> Bool {
    guard let err else { return false }
    switch err {
    case .http(status: 401, _):       return true
    case .orpc(_, status: 401, _):    return true   // oRPC envelope wraps 401, NOT .http
    case .authFailed:                  return true
    case .notSignedIn:                 return true
    default:                           return false
    }
}

/// Renders a "Last sync: …" relative phrase, or "Never synced" when nil.
/// Resolves against `Date()` at call time, so the SyncSettingsView
/// wraps the `Text` invocation in a `TimelineView(.periodic(...))` to
/// keep the phrase advancing while auto-sync is failing (spec §3.3).
func formatLastSyncedAt(_ date: Date?) -> String {
    guard let date else { return "Never synced" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
}

struct SyncSettingsView: View {
    let authSession: AuthSession
    @ObservedObject var syncStore: HostSyncStore
    @ObservedObject var preferences: SyncPreferences
    @Binding var serverURL: String
    @State private var isSigningOut = false
    @State private var isSyncing = false
    @State private var lastSyncError: ServerSyncError?
    @State private var showSignIn = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("URL", text: $serverURL)
                    .disableAutocorrection(true)
                Text("Restart Caterm after changing the server URL.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Account") {
                switch accountState(isSignedIn: authSession.isSignedIn,
                                    lastSyncError: lastSyncError) {
                case .signedOut:
                    Button("Sign In…") { showSignIn = true }
                case .signedIn:
                    Button("Sign Out") { Task { await signOut() } }
                        .disabled(isSigningOut)
                case .sessionExpired:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Session expired")
                            .font(.caption).foregroundColor(.secondary)
                        Button("Sign In Again…") {
                            Task {
                                try? await authSession.signOut()  // clear local cookie
                                showSignIn = true
                                lastSyncError = nil               // hide red text once user moves
                            }
                        }
                    }
                }
            }
            Section("Sync") {
                Toggle("Background sync", isOn: $preferences.periodicSyncEnabled)
                Text("Syncs every 15 minutes and on wake from sleep.")
                    .font(.caption).foregroundColor(.secondary)
                Button("Sync Now") { Task { await syncNow() } }
                    .disabled(!authSession.isSignedIn || isSyncing)
                // TimelineView is load-bearing for failure visibility:
                // formatLastSyncedAt resolves against Date() at body-eval
                // time, so without the periodic re-render the phrase
                // freezes when lastSyncedAt doesn't advance (i.e. when
                // auto-sync is failing — the case we WANT the user to
                // notice). 30 s cadence is responsive enough to feel
                // live but coarse enough not to thrash. Spec §3.3 / §5.5
                // invariant 9.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("Last sync: \(formatLastSyncedAt(syncStore.lastSyncedAt))")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let lastSyncError {
                    Text(lastSyncError.description)
                        .foregroundColor(.red).font(.caption)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .sheet(isPresented: $showSignIn) {
            SignInView(authSession: authSession, onSignedIn: {
                showSignIn = false
            })
        }
    }

    private func signOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        try? await authSession.signOut()
    }

    private func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        lastSyncError = nil
        do {
            try await syncStore.sync()
        } catch let err as ServerSyncError {
            lastSyncError = err
        } catch {
            // syncStore.sync() always throws ServerSyncError when the server
            // is the source of failure. The only way to land here is a
            // CancellationError from the chain replacing this manual pass —
            // which can't happen for manual (manual is gated by
            // currentManualTask, not cancelled by subsequent auto). But we
            // don't want to silently swallow a programming error, so render
            // it as a generic transport failure.
            lastSyncError = .http(status: 0, body: "\(error)")
        }
    }
}
