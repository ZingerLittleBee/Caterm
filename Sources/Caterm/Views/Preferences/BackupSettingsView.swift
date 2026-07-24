import CredentialIdentitySecurity
import CredentialIdentityStore
import SessionStore
import SnippetStore
import SwiftUI

/// Settings > Backup: passphrase-encrypted export/import of the full
/// configuration — the no-iCloud portability path. The heavy lifting
/// (sheets, merge preview, apply) lives in `BackupSettingsSection`;
/// this page adds an at-a-glance summary of what an export would contain.
struct BackupSettingsView: View {
    @ObservedObject var sessionStore: SessionStore
    let snippetStore: SnippetStore?
    let bookmarkStore: RemoteBookmarkStore?
    let credentialIdentityStore: CredentialIdentityStore?
    let credentialIdentityMaterialStore: CredentialIdentityMaterialStore?

    var body: some View {
        Form {
            BackupSettingsSection(
                sessionStore: sessionStore,
                snippetStore: snippetStore,
                bookmarkStore: bookmarkStore,
                credentialIdentityStore: credentialIdentityStore,
                credentialIdentityMaterialStore:
                    credentialIdentityMaterialStore
            )
            Section("What's Included") {
                LabeledContent("Hosts", value: "\(sessionStore.hosts.count)")
                if let credentialIdentityStore {
                    LabeledContent(
                        "Credential identities",
                        value: "\(credentialIdentityStore.identities.count)"
                    )
                }
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
