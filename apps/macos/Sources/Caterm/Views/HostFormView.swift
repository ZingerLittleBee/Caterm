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
	@EnvironmentObject private var sessionStore: SessionStore

	@State private var label = ""
	@State private var hostname = ""
	@State private var port = "22"
	@State private var username = ""
	@State private var credKind: CredKind = .password
	@State private var keyPath = ""
	@State private var hasPassphrase = false
	@State private var pendingSecret = ""
	@State private var jumpHostServerId: String? = nil

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
					LabeledContent("Via host") {
						Picker("Via host", selection: $jumpHostServerId) {
							Text("(none)").tag(String?.none)
							ForEach(eligibleJumpHosts, id: \.host.id) { entry in
								Text("\(entry.host.name) (\(entry.host.username)@\(entry.host.hostname))")
									.tag(String?.some(entry.serverId))
							}
						}
						.pickerStyle(.menu)
						.labelsHidden()
					}
					if !chainPreviewText.isEmpty {
						Text(chainPreviewText)
							.font(.caption)
							.foregroundStyle(chainHasMissingHost ? .red : .secondary)
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

					AuthMethodFields(
						credKind: $credKind,
						keyPath: $keyPath,
						hasPassphrase: $hasPassphrase,
						pendingSecret: $pendingSecret,
						onBrowse: browseKey
					)
					.frame(minHeight: 96, alignment: .top)
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

	private var isValid: Bool {
		guard !hostname.isEmpty,
		      !username.isEmpty,
		      credKind != .keyFile || !keyPath.isEmpty,
		      Int(port).map({ (1...65535).contains($0) }) ?? false
		else { return false }
		// Chain must resolve — reject broken/cyclic jump references.
		let cred: CredentialSource
		switch credKind {
		case .password: cred = .password
		case .keyFile:  cred = .keyFile(keyPath: keyPath, hasPassphrase: hasPassphrase)
		case .agent:    cred = .agent
		}
		var draft = HostFormView.buildHost(
			mode: mode,
			name: resolvedName,
			hostname: hostname,
			port: Int(port) ?? 22,
			username: username,
			credential: cred
		)
		draft.jumpHostServerId = jumpHostServerId
		do {
			_ = try draft.resolvedChain(in: sessionStore.hosts)
		} catch {
			return false
		}
		return true
	}

	private enum ChainPreviewState {
		case none
		case ok(names: [String])
		case missing(names: [String])     // "(deleted)" or "(cycle)" reached
		case cycle(names: [String])
	}

	/// Hosts eligible for use as the jump host for this form's target.
	/// In `.add` mode the new host has no id yet, so only `serverId` presence
	/// is required (no cycle risk from a host that doesn't exist yet).
	private var eligibleJumpHosts: [(host: SSHHost, serverId: String)] {
		let hosts: [SSHHost]
		if case let .edit(currentHost) = mode {
			hosts = HostFormCycleFilter.eligibleJumpHosts(
				editingHost: currentHost,
				allHosts: sessionStore.hosts
			)
		} else {
			hosts = sessionStore.hosts.filter { $0.serverId != nil }
		}
		return hosts.compactMap { h in
			guard let sid = h.serverId else { return nil }
			return (h, sid)
		}
	}

	private var chainPreview: ChainPreviewState {
		guard let sid = jumpHostServerId else { return .none }
		var names: [String] = []
		var cursor: String? = sid
		var visited: Set<String> = []
		while let nextSid = cursor {
			if visited.contains(nextSid) {
				names.append("(cycle)")
				return .cycle(names: names)
			}
			visited.insert(nextSid)
			if let h = sessionStore.hosts.first(where: { $0.serverId == nextSid }) {
				names.append(h.name)
				cursor = h.jumpHostServerId
			} else {
				names.append("(deleted)")
				return .missing(names: names)
			}
		}
		return .ok(names: names)
	}

	/// Human-readable chain preview, e.g. "Will connect via bastion → target".
	/// Returns an empty string when no jump host is selected.
	private var chainPreviewText: String {
		switch chainPreview {
		case .none: return ""
		case .ok(let n), .missing(let n), .cycle(let n):
			return "Will connect via \(n.joined(separator: " → "))"
		}
	}

	private var chainHasMissingHost: Bool {
		switch chainPreview {
		case .missing, .cycle: return true
		case .none, .ok: return false
		}
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
		jumpHostServerId = host.jumpHostServerId
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
		var host = HostFormView.buildHost(
			mode: mode,
			name: resolvedName,
			hostname: hostname,
			port: Int(port) ?? 22,
			username: username,
			credential: cred
		)
		host.jumpHostServerId = jumpHostServerId
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
