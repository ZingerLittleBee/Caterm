import HostSyncStore
import ServerSyncClient
import SwiftUI
import UserNotifications

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
                  lastSyncError: ServerSyncError?,
                  lastSyncErrorKind: SyncErrorKind?) -> AccountState {
    guard isSignedIn else { return .signedOut }
    if (lastSyncError.map(isAuthShape) ?? false) || lastSyncErrorKind == .auth {
        return .sessionExpired
    }
    return .signedIn
}

func shouldShowSyncFailureDetails(for accountState: AccountState) -> Bool {
    accountState == .signedIn
}

/// Renders a "Last sync: …" relative phrase, or "Never synced" when nil.
/// Resolves against `Date()` by default, so the SyncSettingsView
/// wraps the `Text` invocation in a `TimelineView(.periodic(...))` to
/// keep the phrase advancing while auto-sync is failing (spec §3.3).
func formatLastSyncedAt(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "Never synced" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: now)
}

func formatFailingSince(_ since: Date, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: since, relativeTo: now)
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
    @State private var notifyToggleRequestID = 0

    var body: some View {
        let derivedAccountState = accountState(isSignedIn: authSession.isSignedIn,
                                               lastSyncError: lastSyncError,
                                               lastSyncErrorKind: syncStore.lastSyncErrorKind)
        Form {
            Section("Server") {
                TextField("URL", text: $serverURL)
                    .disableAutocorrection(true)
                Text("Restart Caterm after changing the server URL.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Account") {
                switch derivedAccountState {
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
                Toggle("Notify when sync fails", isOn: Binding(
                    get: { preferences.notifyOnFailureEnabled },
                    set: { newValue in
                        Task { await handleNotifyToggle(newValue) }
                    }
                ))
                .disabled(!preferences.periodicSyncEnabled)
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
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("Last sync: \(formatLastSyncedAt(syncStore.lastSyncedAt, now: context.date))")
                        .font(.caption).foregroundColor(.secondary)
                    let failure = currentFailureState(now: context.date)
                    if shouldShowSyncFailureDetails(for: derivedAccountState),
                       case let .failing(_, attempted) = failure {
                        let displaySince = syncStore.failingSince ?? attempted
                        Text("Sync failing since \(formatFailingSince(displaySince, now: context.date))")
                            .foregroundColor(.red).font(.caption)
                        if !preferences.notifyOnFailureEnabled {
                            Text("Turn on 'Notify when sync fails' to be alerted next time.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                if shouldShowSyncFailureDetails(for: derivedAccountState), let lastSyncError {
                    Text(lastSyncError.description)
                        .foregroundColor(.red).font(.caption)
                }
            }
            Section("Terminal") {
                Toggle(
                    "Install Ghostty terminfo on remote hosts",
                    isOn: $preferences.installTerminfoEnabled
                )
                Text("Provides full Ghostty rendering features (true colors, hyperlinks). Falls back to standard terminfo automatically if installation isn't possible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 480)
        .sheet(isPresented: $showSignIn) {
            SignInView(authSession: authSession, onSignedIn: {
                showSignIn = false
                syncStore.clearAuthError()
                syncStore.syncIfSignedIn()
            })
        }
    }

    private func signOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        try? await authSession.signOut()
        syncStore.clearAuthError()
        lastSyncError = nil
    }

    @MainActor
    private func handleNotifyToggle(_ newValue: Bool) async {
        notifyToggleRequestID += 1
        let requestID = notifyToggleRequestID
        guard newValue else {
            preferences.notifyOnFailureEnabled = false
            return
        }
        // UNUserNotificationCenter.current() raises an uncatchable Obj-C
        // NSException (`bundleProxyForCurrentProcess is nil`) when the host
        // process has no bundle identity — i.e., when running the bare debug
        // binary (`make run`) instead of an .app bundle. Bail out cleanly so
        // the toggle simply stays off rather than crashing the whole app.
        guard Bundle.main.bundleIdentifier != nil else {
            preferences.notifyOnFailureEnabled = false
            return
        }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            guard requestID == notifyToggleRequestID else { return }
            preferences.notifyOnFailureEnabled = granted
        } catch {
            guard requestID == notifyToggleRequestID else { return }
            preferences.notifyOnFailureEnabled = false
        }
    }

    private func currentFailureState(now: Date) -> SyncFailureState {
        syncFailureState(
            now: now,
            lastSyncedAt: syncStore.lastSyncedAt,
            lastSyncAttemptedAt: syncStore.lastSyncAttemptedAt,
            lastSyncErrorKind: syncStore.lastSyncErrorKind,
            periodicSyncEnabled: preferences.periodicSyncEnabled,
            failingThreshold: syncStore.periodicInterval
        )
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
