import AppKit
import HostKeyProvisioning
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
/// Private keys are never referenced by user path (ADR 0003): choosing a
/// file or pasting key text stages `PendingKeyMaterial`, which the parent
/// imports into Caterm's managed key storage on Save.
///
/// Fields are stacked (label above a full-width bordered field) per ADR 0001.
struct AuthMethodFields: View {
	@Binding var credKind: CredKind
	@Binding var pendingKey: PendingKeyMaterial?
	@Binding var hasPassphrase: Bool
	@Binding var pendingSecret: String
	/// True when the host already has a key imported into managed storage
	/// (edit / re-key flows) — Save stays enabled without new material.
	var hasExistingManagedKey = false

	@State private var discoveredKeys: [DefaultSSHKeyScanner.DiscoveredKey] = []
	@State private var pasteError: String?

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
					keyStatusRow
					HStack {
						Button("Choose File…") { browseKey() }
							.help("Pick a private key file. Its contents are imported into Caterm — the original file stays where it is and is no longer referenced.")
						if !discoveredKeys.isEmpty {
							Menu {
								ForEach(discoveredKeys) { key in
									Button(key.displayName) {
										stage(.file(path: key.path))
									}
									.help(key.path)
								}
							} label: {
								Image(systemName: "key.horizontal")
							}
							.menuStyle(.borderlessButton)
							.fixedSize()
							.help("Import a key found in ~/.ssh.")
						}
						Button("Paste from Clipboard") { pasteFromClipboard() }
							.help("Import a private key you copied to the clipboard.")
					}
					if let pasteError {
						Text(pasteError)
							.font(.caption)
							.foregroundStyle(.red)
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
				footnote("The key is imported and stored by Caterm (passphrase in Keychain). It syncs with iCloud credential sync when enabled.")
			}
		}
		.textFieldStyle(.roundedBorder)
		.task {
			if credKind == .keyFile, discoveredKeys.isEmpty {
				discoveredKeys = DefaultSSHKeyScanner.scan()
			}
		}
	}

	/// One line reflecting the staged key state so the user always sees
	/// what Save will import (or keep).
	@ViewBuilder
	private var keyStatusRow: some View {
		switch pendingKey {
		case let .file(path):
			stagedRow(
				icon: "doc.badge.plus",
				text: "Will import “\((path as NSString).lastPathComponent)”"
			)
		case .pasted:
			stagedRow(icon: "doc.on.clipboard", text: "Will import pasted key")
		case nil:
			if hasExistingManagedKey {
				HStack(spacing: 6) {
					Image(systemName: "checkmark.seal")
					Text("Key stored in Caterm")
				}
				.font(.callout)
				.foregroundStyle(.secondary)
			} else {
				Text("No key selected")
					.font(.callout)
					.foregroundStyle(.secondary)
			}
		}
	}

	private func stagedRow(icon: String, text: String) -> some View {
		HStack(spacing: 6) {
			Image(systemName: icon)
			Text(text)
			Button {
				stage(nil)
			} label: {
				Image(systemName: "xmark.circle.fill")
					.foregroundStyle(.secondary)
			}
			.buttonStyle(.borderless)
			.help(hasExistingManagedKey ? "Keep the key already stored in Caterm" : "Clear selection")
		}
		.font(.callout)
	}

	private func stage(_ material: PendingKeyMaterial?) {
		pendingKey = material
		pasteError = nil
	}

	private func browseKey() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
			.appendingPathComponent(".ssh")
		if panel.runModal() == .OK, let url = panel.url {
			stage(.file(path: url.path))
		}
	}

	private func pasteFromClipboard() {
		let content = NSPasteboard.general.string(forType: .string) ?? ""
		let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			pasteError = "Clipboard doesn't contain any text."
			return
		}
		guard trimmed.contains("PRIVATE KEY") || trimmed.contains("BEGIN") else {
			pasteError = "Clipboard text doesn't look like a private key."
			return
		}
		stage(.pasted(content: content))
	}

	private func footnote(_ text: String) -> some View {
		Text(text)
			.font(.caption)
			.foregroundStyle(.secondary)
	}
}
