import AppKit
import HostSyncStore
import ServerSyncClient
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
/// Resolves against `Date()` by default, so the CloudSyncSettingsView
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

/// Settings > iCloud Sync: account state plus the host/settings sync
/// controls. Credential sync and backup live on their own Settings
/// sections (`CredentialsSettingsView`, `BackupSettingsView`).
struct CloudSyncSettingsView: View {
    let authSession: AuthSessionProtocol
    @ObservedObject var syncStore: HostSyncStore
    @ObservedObject var preferences: SyncPreferences
    @State private var isSyncing = false
    @State private var lastSyncError: ServerSyncError?
    @State private var notifyToggleRequestID = 0
    /// `AuthSessionProtocol` is a plain (non-`ObservableObject`) reference
    /// type whose `isSignedIn` flips asynchronously (on launch `refresh()`
    /// and on `.CKAccountChanged`). Reading it directly in `body` left the
    /// Account section and `Sync Now` showing stale state until some other
    /// `@ObservedObject` happened to publish. Mirror it into observed
    /// `@State`, seeded on appear and refreshed when the account session
    /// posts `.catermICloudAccountChanged` (posted *after* its
    /// `refresh()`), so the account UI is always live.
    @State private var isSignedIn = false

    var body: some View {
        let derivedAccountState = accountState(isSignedIn: isSignedIn)
        Form {
            Section {
                LabeledContent("iCloud Account") {
                    AccountStateBadge(state: derivedAccountState)
                }
                if derivedAccountState == .signedOut {
                    Text("Sign in to your iCloud account in System Settings to enable sync.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open iCloud Settings…") { openICloudSystemSettings() }
                }
            }
            Section {
                Toggle("Background sync", isOn: $preferences.periodicSyncEnabled)
                Toggle("Notify when sync fails", isOn: Binding(
                    get: { preferences.notifyOnFailureEnabled },
                    set: { newValue in
                        Task { await handleNotifyToggle(newValue) }
                    }
                ))
                .disabled(!preferences.periodicSyncEnabled)
                Text("Syncs every 15 minutes and on wake from sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                // TimelineView is load-bearing for failure visibility:
                // formatLastSyncedAt resolves against Date() at body-eval
                // time, so without the periodic re-render the phrase
                // freezes when lastSyncedAt doesn't advance (i.e. when
                // auto-sync is failing — the case we WANT the user to
                // notice). 30 s cadence is responsive enough to feel
                // live but coarse enough not to thrash. Spec §3.3 / §5.5
                // invariant 9.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LabeledContent("Last sync") {
                        Text(formatLastSyncedAt(syncStore.lastSyncedAt, now: context.date))
                            .foregroundStyle(.secondary)
                    }
                    let failure = currentFailureState(now: context.date)
                    if shouldShowSyncFailureDetails(for: derivedAccountState),
                       case let .failing(_, attempted) = failure {
                        let displaySince = syncStore.failingSince ?? attempted
                        Text("Sync failing since \(formatFailingSince(displaySince, now: context.date))")
                            .foregroundStyle(.red).font(.caption)
                        if !preferences.notifyOnFailureEnabled {
                            Text("Turn on 'Notify when sync fails' to be alerted next time.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if shouldShowSyncFailureDetails(for: derivedAccountState), let lastSyncError {
                    Text(lastSyncError.description)
                        .foregroundStyle(.red).font(.caption)
                }
                HStack {
                    Button("Sync Now") { Task { await syncNow() } }
                        .disabled(!isSignedIn || isSyncing)
                    if isSyncing || syncStore.isSyncing {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { isSignedIn = authSession.isSignedIn }
        .onReceive(NotificationCenter.default.publisher(for: .catermICloudAccountChanged)) { _ in
            isSignedIn = authSession.isSignedIn
        }
    }

    private func openICloudSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane")
        else { return }
        NSWorkspace.shared.open(url)
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

/// Capsule status badge for the account row — green "Signed in" or
/// orange "Not signed in".
private struct AccountStateBadge: View {
    let state: AccountState

    private var title: String {
        switch state {
        case .signedIn: return "Signed in"
        case .signedOut: return "Not signed in"
        }
    }

    private var color: Color {
        switch state {
        case .signedIn: return .green
        case .signedOut: return .orange
        }
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: .capsule)
            .accessibilityLabel("iCloud account: \(title)")
    }
}
