import AppKit
import SessionStore
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
	@Environment(\.dismiss) var dismiss

	@State var name = ""
	@State var hostname = ""
	@State var port = "22"
	@State var username = ""
	@State var credKind: CredKind = .password
	@State var keyPath = ""
	@State var hasPassphrase = false
	@State var pendingSecret = ""

	enum CredKind: String, CaseIterable, Identifiable {
		case password
		case keyFile = "key file"
		case agent
		var id: String { rawValue }
	}

	var body: some View {
		Form {
			Section("Connection") {
				TextField("Name (display)", text: $name)
				TextField("Hostname", text: $hostname)
				TextField("Port", text: $port)
				TextField("Username", text: $username)
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
					Button("Cancel") { dismiss() }
					Spacer()
					Button("Save") { submit() }
						.keyboardShortcut(.return)
						.disabled(!isValid)
				}
			}
		}
		.padding(20)
		.frame(width: 480)
		.onAppear { populate() }
	}

	var isValid: Bool {
		!name.isEmpty
			&& !hostname.isEmpty
			&& !username.isEmpty
			&& (credKind != .keyFile || !keyPath.isEmpty)
			&& Int(port) != nil
	}

	func populate() {
		if case let .edit(host) = mode {
			name = host.name
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

	func submit() {
		let cred: CredentialSource
		switch credKind {
		case .password:
			cred = .password
		case .keyFile:
			cred = .keyFile(keyPath: keyPath, hasPassphrase: hasPassphrase)
		case .agent:
			cred = .agent
		}
		let id: UUID = {
			if case let .edit(existing) = mode { return existing.id }
			return UUID()
		}()
		let host = SSHHost(
			id: id,
			name: name,
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
}
