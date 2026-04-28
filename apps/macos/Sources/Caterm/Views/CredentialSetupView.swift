import AppKit
import SessionStore
import SSHCommandBuilder
import SwiftUI

/// Sheet shown when the user tries to connect to a host that has no
/// usable local credential (typically a host pulled from the server on
/// a fresh device). Captures auth method + secret, then hands off to
/// the parent via `onSaved` (async throws) which performs the actual
/// Keychain + SessionStore writes. The sheet only dismisses on a
/// successful Save; failures are rendered inline via `errorMessage`.
struct CredentialSetupView: View {
	let host: SSHHost
	var onSaved: (CredentialSource, String?) async throws -> Void
	var onCancel: () -> Void

	@Environment(\.dismiss) var dismiss

	@State var credKind: CredKind = .password
	@State var keyPath: String = ""
	@State var hasPassphrase = false
	@State var pendingSecret: String = ""
	@State var errorMessage: String?
	@State var isSaving = false

	enum CredKind: String, CaseIterable, Identifiable {
		case password
		case keyFile = "key file"
		case agent
		var id: String { rawValue }
	}

	var body: some View {
		Form {
			Section {
				VStack(alignment: .leading, spacing: 2) {
					Text(host.name).font(.headline)
					Text("\(host.username)@\(host.hostname):\(host.port)")
						.font(.caption)
						.foregroundColor(.secondary)
				}
			}

			Section("Authentication") {
				Picker("Method", selection: $credKind) {
					ForEach(CredKind.allCases) { Text($0.rawValue).tag($0) }
				}
				.pickerStyle(.segmented)

				if credKind == .keyFile {
					HStack {
						TextField("Private key path", text: $keyPath)
						Button("Browse…") { browseKey() }
					}
					Toggle("Key has passphrase", isOn: $hasPassphrase)
				}

				if credKind == .password {
					SecureField("Password (stored in Keychain)", text: $pendingSecret)
				} else if credKind == .keyFile, hasPassphrase {
					SecureField("Passphrase (stored in Keychain)", text: $pendingSecret)
				}
			}

			Section {
				HStack {
					Button("Cancel") { onCancel() }
						.disabled(isSaving)
					Spacer()
					Button("Save") { save() }
						.keyboardShortcut(.return)
						.disabled(!isValid || isSaving)
				}
			}

			if let errorMessage {
				Section {
					Text(errorMessage)
						.foregroundColor(.red)
						.font(.caption)
				}
			}
		}
		.padding(20)
		.frame(width: 480)
	}

	/// Save is enabled only when the inputs are usable. For .keyFile we
	/// resolve `~` and require the file to actually exist — typing a
	/// nonexistent path keeps Save disabled (no error needed; the
	/// disabled button is the affordance). This also closes the loop
	/// where a literal `~/.ssh/...` would round-trip through Save and
	/// the next connect would still see needsCredentialSetup == true,
	/// re-popping the sheet.
	var isValid: Bool {
		switch credKind {
		case .password:
			return !pendingSecret.isEmpty
		case .keyFile:
			guard canonicalizedKeyPath() != nil else { return false }
			if hasPassphrase { return !pendingSecret.isEmpty }
			return true
		case .agent:
			return true
		}
	}

	func canonicalizedKeyPath() -> String? {
		let trimmed = keyPath.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return nil }
		let expanded = (trimmed as NSString).expandingTildeInPath
		guard FileManager.default.fileExists(atPath: expanded) else { return nil }
		return expanded
	}

	func browseKey() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
			.appendingPathComponent(".ssh")
		if panel.runModal() == .OK, let url = panel.url {
			keyPath = url.path
		}
	}

	func save() {
		let cred: CredentialSource
		let secret: String?
		switch credKind {
		case .password:
			cred = .password
			secret = pendingSecret
		case .keyFile:
			guard let path = canonicalizedKeyPath() else { return }
			cred = .keyFile(keyPath: path, hasPassphrase: hasPassphrase)
			secret = hasPassphrase ? pendingSecret : nil
		case .agent:
			cred = .agent
			secret = nil
		}

		errorMessage = nil
		isSaving = true
		Task {
			do {
				try await onSaved(cred, secret)
				// Parent is responsible for dismissing on success
				// (it owns pendingCredentialHost binding).
			} catch {
				await MainActor.run {
					errorMessage = error.localizedDescription
					isSaving = false
				}
			}
		}
	}
}
