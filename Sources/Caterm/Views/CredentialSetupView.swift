import AppKit
import HostKeyProvisioning
import SessionStore
import SSHCommandBuilder
import SwiftUI

/// Sheet shown when the user tries to connect to a host that has no
/// usable local credential (typically a host pulled from the server on
/// a fresh device). Captures auth method + secret (+ key material to
/// import into managed storage — ADR 0003), then hands off to the
/// parent via `onSaved` (async throws) which performs the actual
/// Keychain / ManagedKeyStore / SessionStore writes. The sheet only
/// dismisses on a successful Save; failures are rendered inline via
/// `errorMessage`.
struct CredentialSetupView: View {
	let host: SSHHost
	var onSaved: (CredentialSource, String?, PendingKeyMaterial?) async throws -> Void
	var onCancel: () -> Void

	@Environment(\.dismiss) var dismiss

	@State var credKind: CredKind = .password
	@State var pendingKey: PendingKeyMaterial?
	@State var hasPassphrase = false
	@State var pendingSecret: String = ""
	@State var errorMessage: String?
	@State var isSaving = false

	var body: some View {
		VStack(spacing: 0) {
			Form {
				Section {
					VStack(alignment: .leading, spacing: 2) {
						Text(host.name).font(.headline)
						Text("\(host.username)@\(host.hostname):\(host.port)")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}

				Section("Authentication") {
					Picker("Method", selection: $credKind) {
						ForEach(CredKind.allCases) { kind in
							Text(kind.displayName).tag(kind)
						}
					}
					.pickerStyle(.segmented)

					AuthMethodFields(
						credKind: $credKind,
						pendingKey: $pendingKey,
						hasPassphrase: $hasPassphrase,
						pendingSecret: $pendingSecret
					)
					.frame(minHeight: 96, alignment: .top)
				}

				if let errorMessage {
					Section {
						Text(errorMessage)
							.font(.caption)
							.foregroundStyle(.red)
					}
				}
			}
			.formStyle(.grouped)

			Divider()

			HStack {
				Button("Cancel") { onCancel() }
					.keyboardShortcut(.cancelAction)
					.disabled(isSaving)
				Spacer()
				Button("Save") { save() }
					.keyboardShortcut(.defaultAction)
					.disabled(!isValid || isSaving)
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 14)
		}
		.frame(width: 480, height: 420)
	}

	/// Save is enabled only when the inputs are usable. For .keyFile the
	/// user must have staged key material (file or paste) — this sheet
	/// only appears when no usable local credential exists, so there is
	/// no managed key to fall back on.
	var isValid: Bool {
		switch credKind {
		case .password:
			return !pendingSecret.isEmpty
		case .keyFile:
			guard pendingKey != nil else { return false }
			if hasPassphrase { return !pendingSecret.isEmpty }
			return true
		}
	}

	func save() {
		let cred: CredentialSource
		let secret: String?
		let keyMaterial: PendingKeyMaterial?
		switch credKind {
		case .password:
			cred = .password
			secret = pendingSecret
			keyMaterial = nil
		case .keyFile:
			guard let staged = pendingKey else { return }
			// Placeholder path — the parent's provisioning step rewrites
			// keyPath to the managed location after importing the bytes.
			cred = .keyFile(keyPath: "", hasPassphrase: hasPassphrase)
			secret = hasPassphrase ? pendingSecret : nil
			keyMaterial = staged
		}

		errorMessage = nil
		isSaving = true
		Task {
			do {
				try await onSaved(cred, secret, keyMaterial)
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
