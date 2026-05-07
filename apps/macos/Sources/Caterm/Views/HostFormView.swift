import AppKit
import SessionStore
import SettingsStore
import SSHCommandBuilder
import SwiftUI

enum HostFormMode {
	case add
	case edit(SSHHost)
}

/// Modal sheet for adding or editing a saved host. Calls `onSubmit(host, secret)`
/// when the user clicks Save. The optional `secret` is the password (for
/// password auth), the passphrase (for key+passphrase auth), or `nil` for agent
/// / unencrypted-key / edit-without-secret-change.
struct HostFormView: View {
	let mode: HostFormMode
	let onSubmit: (SSHHost, String?) -> Void
	@Environment(\.dismiss) private var dismiss

	@State private var label = ""
	@State private var hostname = ""
	@State private var port = "22"
	@State private var username = ""
	@State private var credKind: CredKind = .password
	@State private var keyPath = ""
	@State private var hasPassphrase = false
	@State private var pendingSecret = ""

	enum CredKind: CaseIterable, Identifiable {
		case password
		case keyFile
		case agent

		var id: Self { self }

		var displayName: String {
			switch self {
			case .password: "Password"
			case .keyFile: "Key File"
			case .agent: "Agent"
			}
		}
	}

	var body: some View {
		VStack(spacing: 0) {
			Form {
				Section("Connection") {
					LabeledContent("Label") {
						TextField("", text: $label, prompt: Text("Optional"))
					}
					LabeledContent("Hostname") {
						TextField("", text: $hostname)
					}
					LabeledContent("Port") {
						TextField("", text: $port)
					}
					LabeledContent("Username") {
						TextField("", text: $username)
					}
				}

				Section("Authentication") {
					Picker("Method", selection: $credKind) {
						ForEach(CredKind.allCases) { kind in
							Text(kind.displayName).tag(kind)
						}
					}
					.pickerStyle(.segmented)
					.labelsHidden()

					authDetails
				}

				// Theme override only makes sense for an existing host —
				// the override key is the host's UUID, which doesn't exist
				// yet in the `.add` case.
				if case let .edit(host) = mode {
					Section("Theme Override") {
						HostThemeOverridePicker(hostId: HostId(host.id.uuidString))
					}
				}
			}
			.formStyle(.grouped)
			.scrollDisabled(true)

			Divider()

			HStack {
				Button("Cancel") { dismiss() }
					.keyboardShortcut(.cancelAction)
				Spacer()
				Button("Save") { submit() }
					.keyboardShortcut(.defaultAction)
					.disabled(!isValid)
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 14)
		}
		.frame(width: 520, height: 460)
		.onAppear { populate() }
	}

	/// Variable-content area for the chosen credential method. Reserves a
	/// consistent minimum height across all variants so that switching
	/// methods doesn't shift the buttons or other sections.
	@ViewBuilder
	private var authDetails: some View {
		VStack(alignment: .leading, spacing: 8) {
			switch credKind {
			case .password:
				SecureField("Password", text: $pendingSecret)
					.textContentType(.password)
				footnote("Stored in Keychain.")
			case .keyFile:
				HStack {
					TextField("Private key path", text: $keyPath)
					Button("Browse…") { browseKey() }
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
			case .agent:
				footnote("Caterm will use the running ssh-agent for authentication.")
			}
		}
		.frame(minHeight: 96, alignment: .top)
	}

	private func footnote(_ text: String) -> some View {
		Text(text)
			.font(.caption)
			.foregroundStyle(.secondary)
	}

	private var isValid: Bool {
		!hostname.isEmpty
			&& !username.isEmpty
			&& (credKind != .keyFile || !keyPath.isEmpty)
			&& (Int(port).map { (1...65535).contains($0) } ?? false)
	}

	/// Falls back to `username@hostname` when the user leaves the label
	/// blank so the host always has something user-visible to render.
	private var resolvedName: String {
		let trimmed = label.trimmingCharacters(in: .whitespaces)
		if !trimmed.isEmpty { return trimmed }
		return "\(username)@\(hostname)"
	}

	private func populate() {
		guard case let .edit(host) = mode else { return }
		// Only carry the existing name into the editable field when it
		// isn't just the auto-derived `username@hostname` fallback —
		// otherwise editing would surface the fallback as if the user
		// had typed it, defeating the optional-label affordance.
		let derived = "\(host.username)@\(host.hostname)"
		label = host.name == derived ? "" : host.name
		hostname = host.hostname
		port = String(host.port)
		username = host.username
		switch host.credential {
		case .password:
			credKind = .password
		case let .keyFile(p, hp):
			credKind = .keyFile
			keyPath = p
			hasPassphrase = hp
		case .agent:
			credKind = .agent
		}
	}

	private func browseKey() {
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

	private func submit() {
		let cred: CredentialSource
		switch credKind {
		case .password:
			cred = .password
		case .keyFile:
			cred = .keyFile(keyPath: keyPath, hasPassphrase: hasPassphrase)
		case .agent:
			cred = .agent
		}
		let host = HostFormView.buildHost(
			mode: mode,
			name: resolvedName,
			hostname: hostname,
			port: Int(port) ?? 22,
			username: username,
			credential: cred
		)
		let secret: String? = {
			if pendingSecret.isEmpty { return nil }
			switch cred {
			case .password:
				return pendingSecret
			case .keyFile(_, true):
				return pendingSecret
			default:
				return nil
			}
		}()
		onSubmit(host, secret)
	}

	/// Build the `SSHHost` payload for `onSubmit`. In `.edit` mode this
	/// must spread from the existing host so hidden fields (`serverId`,
	/// `createdAt`, `credentialMaterialDirty`) survive a metadata-only
	/// edit — constructing a fresh `SSHHost` with the default initializer
	/// erases `serverId` and causes the next sync pass to treat the
	/// renamed host as a new local insert, leaving the original CloudKit
	/// record orphaned and re-pulled as a duplicate.
	static func buildHost(
		mode: HostFormMode,
		name: String,
		hostname: String,
		port: Int,
		username: String,
		credential: CredentialSource
	) -> SSHHost {
		if case let .edit(existing) = mode {
			var h = existing
			h.name = name
			h.hostname = hostname
			h.port = port
			h.username = username
			h.credential = credential
			return h
		}
		return SSHHost(
			name: name,
			hostname: hostname,
			port: port,
			username: username,
			credential: credential
		)
	}
}
