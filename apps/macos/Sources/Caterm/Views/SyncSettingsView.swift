import CredentialSync
import CredentialSyncStore
import HostSyncStore
import ServerSyncClient
import SessionStore
import SwiftUI
import UserNotifications

/// Account state derived from iCloud sign-in. Binary post-Plan-E: the email/
/// password "session expired" branch is gone — iCloud doesn't expose a
/// pre-failure expired state, and recovery is to sign back in via System
/// Settings, not via the app.
enum AccountState: Equatable {
    case signedOut
    case signedIn
}

/// Pure derivation — no SwiftUI state. Tested directly in
/// `SyncSettingsAccountStateTests` without any view harness.
func accountState(isSignedIn: Bool) -> AccountState {
    isSignedIn ? .signedIn : .signedOut
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
    let authSession: AuthSessionProtocol
    @ObservedObject var syncStore: HostSyncStore
    @ObservedObject var preferences: SyncPreferences
    let credentialSync: CredentialSyncPreferencesStore?
    let credentialSyncCoordinator: CredentialSyncCoordinator?
    let sessionStore: SessionStore?
    @State private var isSyncing = false
    @State private var lastSyncError: ServerSyncError?
    @State private var notifyToggleRequestID = 0

    init(
        authSession: AuthSessionProtocol,
        syncStore: HostSyncStore,
        preferences: SyncPreferences,
        credentialSync: CredentialSyncPreferencesStore? = nil,
        credentialSyncCoordinator: CredentialSyncCoordinator? = nil,
        sessionStore: SessionStore? = nil
    ) {
        self.authSession = authSession
        self.syncStore = syncStore
        self.preferences = preferences
        self.credentialSync = credentialSync
        self.credentialSyncCoordinator = credentialSyncCoordinator
        self.sessionStore = sessionStore
    }

    var body: some View {
        let derivedAccountState = accountState(isSignedIn: authSession.isSignedIn)
        Form {
            Section("Account") {
                switch derivedAccountState {
                case .signedOut:
                    Text("Not signed in to iCloud")
                        .foregroundColor(.secondary)
                    Text("Sign in to your iCloud account in System Settings to enable sync.")
                        .font(.caption).foregroundColor(.secondary)
                case .signedIn:
                    Text("Signed in to iCloud")
                        .foregroundColor(.secondary)
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
            if let credentialSync, let credentialSyncCoordinator, let sessionStore {
                CredentialSyncSection(
                    prefsStore: credentialSync,
                    coordinator: credentialSyncCoordinator,
                    sessionStore: sessionStore,
                    triggerSync: { [weak syncStore] in syncStore?.syncIfSignedIn() }
                )
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
