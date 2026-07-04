import ManagedKeyStore
import SessionStore
import SnippetStore
import SwiftUI

/// Settings > Backup: passphrase-encrypted export/import of the full
/// configuration — the no-iCloud portability path. The heavy lifting
/// (sheets, merge preview, apply) lives in `BackupSettingsSection`;
/// this page adds an at-a-glance summary of what an export would contain.
struct BackupSettingsView: View {
    @ObservedObject var sessionStore: SessionStore
    let managedKeys: ManagedKeyStore
    let snippetStore: SnippetStore?
    let bookmarkStore: RemoteBookmarkStore?

    var body: some View {
        Form {
            BackupSettingsSection(
                sessionStore: sessionStore,
                managedKeys: managedKeys,
                snippetStore: snippetStore,
                bookmarkStore: bookmarkStore
            )
            Section("What's Included") {
                LabeledContent("Hosts", value: "\(sessionStore.hosts.count)")
                if let snippetStore {
                    LabeledContent("Snippets", value: "\(snippetStore.snippets.count)")
                }
                LabeledContent("Settings", value: "All application settings")
                Text("Credentials and private keys are included only when you choose to during export.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
