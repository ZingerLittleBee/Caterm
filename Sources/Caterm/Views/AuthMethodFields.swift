import SwiftUI

/// Method-conditional auth field group. Used by both `CredentialSetupView`
/// and `HostFormView`. Reserves a consistent minimum height across all
/// `CredKind` variants so that flipping the segmented picker doesn't shift
/// the parent sheet's footer buttons.
struct AuthMethodFields: View {
	@Binding var credKind: CredKind
	@Binding var keyPath: String
	@Binding var hasPassphrase: Bool
	@Binding var pendingSecret: String
	var onBrowse: () -> Void

	@State private var discoveredKeys: [DefaultSSHKeyScanner.DiscoveredKey] = []

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			switch credKind {
			case .password:
				SecureField("Password", text: $pendingSecret)
					.textContentType(.password)
					.help("Stored in your macOS Keychain. Synced to your other devices when iCloud credential sync is enabled.")
				footnote("Stored in Keychain. Syncs with iCloud credential sync.")

			case .keyFile:
				HStack {
					TextField("e.g. ~/.ssh/id_ed25519", text: $keyPath)
						.help("Path to your SSH private key. A key you pick here is uploaded and synced to your other devices when iCloud credential sync is on.")
					if !discoveredKeys.isEmpty {
						Menu {
							ForEach(discoveredKeys) { key in
								Button(key.displayName) { keyPath = key.path }
									.help(key.path)
							}
						} label: {
							Image(systemName: "key.horizontal")
						}
						.menuStyle(.borderlessButton)
						.fixedSize()
						.help("Pick a key found in ~/.ssh. Choosing one here makes it this host's key (and syncs it when iCloud credential sync is on).")
					}
					Button("Browse…") { onBrowse() }
				}
				Toggle("Key has passphrase", isOn: $hasPassphrase)
					.help("Enable if the private key is encrypted with a passphrase. The passphrase is stored in your Keychain.")
				if hasPassphrase {
					SecureField("Passphrase", text: $pendingSecret)
						.textContentType(.password)
						.help("Stored in your macOS Keychain, never written to disk in plaintext.")
				}
				footnote(
					hasPassphrase
						? "Path stored locally; passphrase stored in Keychain. The key itself syncs with iCloud credential sync."
						: "The key you pick syncs with iCloud credential sync. Keys auto-discovered in ~/.ssh are never uploaded unless you opt in under Settings → Sync."
				)
			}
		}
		.task {
			if credKind == .keyFile, discoveredKeys.isEmpty {
				discoveredKeys = DefaultSSHKeyScanner.scan()
			}
		}
	}

	private func footnote(_ text: String) -> some View {
		Text(text)
			.font(.caption)
			.foregroundStyle(.secondary)
	}
}
