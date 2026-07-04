import SwiftUI

/// Small label rendered above a form field. Shared by `HostFormView` and
/// `AuthMethodFields` so every stacked field reads the same (see ADR 0001).
struct FieldLabel: View {
	let text: String

	init(_ text: String) { self.text = text }

	var body: some View {
		Text(text)
			.font(.subheadline.weight(.medium))
			.foregroundStyle(.secondary)
	}
}

/// Method-conditional auth field group. Used by both `CredentialSetupView`
/// and `HostFormView`. Reserves a consistent minimum height across all
/// `CredKind` variants so that flipping the segmented picker doesn't shift
/// the parent sheet's footer buttons.
///
/// Fields are stacked (label above a full-width bordered field) per ADR 0001.
struct AuthMethodFields: View {
	@Binding var credKind: CredKind
	@Binding var keyPath: String
	@Binding var hasPassphrase: Bool
	@Binding var pendingSecret: String
	var onBrowse: () -> Void

	@State private var discoveredKeys: [DefaultSSHKeyScanner.DiscoveredKey] = []

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			switch credKind {
			case .password:
				VStack(alignment: .leading, spacing: 5) {
					FieldLabel("Password")
					SecureField("", text: $pendingSecret, prompt: Text("Stored in macOS Keychain"))
						.textContentType(.password)
						.help("Stored in your macOS Keychain. Synced to your other devices when iCloud credential sync is enabled.")
				}
				footnote("Stored in Keychain. Syncs with iCloud credential sync.")

			case .keyFile:
				VStack(alignment: .leading, spacing: 5) {
					FieldLabel("Private key")
					HStack {
						TextField("", text: $keyPath, prompt: Text("~/.ssh/id_ed25519"))
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
				}
				Toggle("Key has passphrase", isOn: $hasPassphrase)
					.help("Enable if the private key is encrypted with a passphrase. The passphrase is stored in your Keychain.")
				if hasPassphrase {
					VStack(alignment: .leading, spacing: 5) {
						FieldLabel("Passphrase")
						SecureField("", text: $pendingSecret, prompt: Text("Stored in macOS Keychain"))
							.textContentType(.password)
							.help("Stored in your macOS Keychain, never written to disk in plaintext.")
					}
				}
				footnote(
					hasPassphrase
						? "Path stored locally; passphrase stored in Keychain. The key itself syncs with iCloud credential sync."
						: "The key you pick syncs with iCloud credential sync. Keys auto-discovered in ~/.ssh are never uploaded unless you opt in under Settings → Sync."
				)
			}
		}
		.textFieldStyle(.roundedBorder)
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
