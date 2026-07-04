import CredentialSync
import CredentialSyncStore
import HostSyncStore
import SessionStore
import SwiftUI

/// Settings > Credentials: iCloud credential sync (end-to-end encrypted)
/// plus the SSH key auto-upload policy. Separated from the iCloud Sync
/// section because credential sync has its own state machine (encryption
/// key readiness can fail independently of host-metadata sync).
struct CredentialsSettingsView: View {
    @ObservedObject var preferences: SyncPreferences
    let credentialSync: CredentialSyncPreferencesStore?
    let credentialSyncCoordinator: CredentialSyncCoordinator?
    let sessionStore: SessionStore?
    let triggerSync: () -> Void

    var body: some View {
        Form {
            if let credentialSync, let credentialSyncCoordinator, let sessionStore {
                CredentialSyncSection(
                    prefsStore: credentialSync,
                    coordinator: credentialSyncCoordinator,
                    sessionStore: sessionStore,
                    triggerSync: triggerSync
                )
            }
            Section("SSH Keys") {
                Toggle(
                    "Auto-upload default keys after a successful connection",
                    isOn: $preferences.autoUploadDefaultKeysEnabled
                )
                .help("Off by default. Keys found by scanning ~/.ssh are never uploaded unless you enable this — and even then, only a key that produced a successful connection is synced.")
                Text("A key you explicitly pick for a host always syncs (when iCloud credential sync is on). Keys discovered automatically in ~/.ssh stay on this device unless this is enabled, and only after one of them successfully connects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
