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

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			switch credKind {
			case .password:
				SecureField("Password", text: $pendingSecret)
					.textContentType(.password)
				footnote("Stored in Keychain.")

			case .keyFile:
				HStack {
					TextField("Private key path", text: $keyPath)
					Button("Browse…") { onBrowse() }
				}
				Toggle("Key has passphrase", isOn: $hasPassphrase)
				if hasPassphrase {
					SecureField("Passphrase", text: $pendingSecret)
						.textContentType(.password)
				}
				footnote(
					hasPassphrase
						? "Path stored locally; passphrase stored in Keychain."
						: "Path stored locally."
				)
			}
		}
	}

	private func footnote(_ text: String) -> some View {
		Text(text)
			.font(.caption)
			.foregroundStyle(.secondary)
	}
}
