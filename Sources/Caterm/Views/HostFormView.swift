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
	@State private var jumpHostId: UUID? = nil
	@State private var forwards: [PortForward] = []
	@State private var icon: String? = nil

	var body: some View {
		VStack(spacing: 0) {
			Form {
				Section("Connection") {
					LabeledContent("Label") {
						TextField("", text: $label, prompt: Text("Optional"))
					}
					LabeledContent("Icon") {
						HostIconPicker(
							icon: $icon,
							fallbackSymbol: credentialIconFallback
						)
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
						Picker("Via host", selection: $jumpHostId) {
							Text("(none)").tag(UUID?.none)
							ForEach(eligibleJumpHosts, id: \.id) { host in
								Text("\(host.name) (\(host.username)@\(host.hostname))")
									.tag(UUID?.some(host.id))
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

				Section("Port Forwarding") {
					if forwards.isEmpty {
						HStack {
							Text("No port forwards")
								.foregroundStyle(.secondary)
							Spacer()
							Button("+ Add") { addForward() }
								.buttonStyle(.borderless)
						}
					} else {
						ForwardListEditor(
							forwards: $forwards,
							onAdd: addForward,
							onDelete: deleteForward
						)
					}
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
		.frame(width: 520, height: 560)
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
		draft.jumpHostId = jumpHostId
		draft.jumpHostServerId = jumpHost.flatMap(\.serverId)
		do {
			_ = try draft.resolvedChain(in: sessionStore.hosts)
		} catch {
			return false
		}
		guard (try? PortForward.validateCollection(forwards)) != nil else { return false }
		return true
	}

	private enum ChainPreviewState {
		case none
		case ok(names: [String])
		case missing(names: [String])     // "(deleted)" or "(cycle)" reached
		case cycle(names: [String])
	}

	/// Hosts eligible for use as the jump host for this form's target.
	/// In `.add` mode every existing host is eligible because the new host
	/// does not exist in the graph yet and therefore cannot participate in a cycle.
	private var eligibleJumpHosts: [SSHHost] {
		if case let .edit(currentHost) = mode {
			return HostFormCycleFilter.eligibleJumpHosts(
				editingHost: currentHost,
				allHosts: sessionStore.hosts
			)
		}
		return sessionStore.hosts
	}

	private var chainPreview: ChainPreviewState {
		guard let jumpHost else { return .none }
		var names: [String] = []
		var cursor: SSHHost? = jumpHost
		var visited: Set<UUID> = []
		while let nextHost = cursor {
			if visited.contains(nextHost.id) {
				names.append("(cycle)")
				return .cycle(names: names)
			}
			visited.insert(nextHost.id)
			names.append(nextHost.name)
			if let nextId = nextHost.jumpHostId {
				cursor = sessionStore.hosts.first(where: { $0.id == nextId })
				if cursor == nil {
					names.append("(deleted)")
					return .missing(names: names)
				}
				continue
			}
			if let nextSid = nextHost.jumpHostServerId {
				cursor = sessionStore.hosts.first(where: { $0.serverId == nextSid })
				if cursor == nil {
					names.append("(deleted)")
					return .missing(names: names)
				}
				continue
			}
			cursor = nil
		}
		return .ok(names: names)
	}

	private var jumpHost: SSHHost? {
		guard let jumpHostId else { return nil }
		return sessionStore.hosts.first(where: { $0.id == jumpHostId })
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

	/// The credential-derived default icon for the currently selected auth
	/// method, previewed by `HostIconPicker` when no override is chosen.
	private var credentialIconFallback: String {
		switch credKind {
		case .password: return defaultHostIconName(for: .password)
		case .keyFile:  return defaultHostIconName(for: .keyFile(keyPath: "", hasPassphrase: false))
		}
	}

	/// Falls back to `username@hostname` when the user leaves the label
	/// blank so the host always has something user-visible to render.
	private var resolvedName: String {
		let trimmed = label.trimmingCharacters(in: .whitespaces)
		if !trimmed.isEmpty { return trimmed }
		return "\(username)@\(hostname)"
	}

	private func addForward() {
		let nextBind = lowestUnusedBindPort(start: 8080)
		forwards.append(PortForward(kind: .local, bindPort: nextBind,
		                            remoteHost: "localhost", remotePort: 8080))
	}

	private func deleteForward(_ id: UUID) {
		forwards.removeAll { $0.id == id }
	}

	private func lowestUnusedBindPort(start: Int) -> Int {
		let used = Set(forwards.map { $0.bindPort })
		var p = start
		while used.contains(p) { p += 1 }
		return p
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
		jumpHostId = Self.jumpHostIdForForm(host: host, allHosts: sessionStore.hosts)
		forwards = host.forwards
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
		host.jumpHostId = jumpHostId
		host.jumpHostServerId = jumpHost.flatMap(\.serverId)
		host.forwards = forwards
		host.icon = icon
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

	static func jumpHostIdForForm(host: SSHHost, allHosts: [SSHHost]) -> UUID? {
		if let jumpHostId = host.jumpHostId {
			return jumpHostId
		}
		guard let jumpHostServerId = host.jumpHostServerId else { return nil }
		return allHosts.first(where: { $0.serverId == jumpHostServerId })?.id
	}
}

private struct ForwardListEditor: View {
	@Binding var forwards: [PortForward]
	let onAdd: () -> Void
	let onDelete: (UUID) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			ScrollView {
				LazyVStack(spacing: 4) {
					ForEach($forwards) { $forward in
						ForwardRow(forward: $forward, onDelete: { onDelete(forward.id) })
					}
				}
			}
			.frame(maxHeight: forwards.count > 5 ? 180 : nil)

			Button("+ Add port forward", action: onAdd)
				.buttonStyle(.borderless)
		}
	}
}

private struct ForwardRow: View {
	@Binding var forward: PortForward
	let onDelete: () -> Void

	var body: some View {
		HStack(spacing: 8) {
			Picker("", selection: $forward.kind) {
				Text("L").tag(PortForward.Kind.local)
				Text("R").tag(PortForward.Kind.remote)
				Text("D").tag(PortForward.Kind.dynamic)
			}
			.pickerStyle(.menu)
			.frame(width: 60)
			.labelsHidden()
			.onChange(of: forward.kind) { _, newKind in
				if newKind == .dynamic {
					forward.remoteHost = nil
					forward.remotePort = nil
				} else if forward.remoteHost == nil {
					forward.remoteHost = "localhost"
					forward.remotePort = forward.bindPort
				}
			}

			TextField("Bind port", value: $forward.bindPort, format: .number)
				.frame(width: 80)

			if forward.kind == .dynamic {
				Text("(dynamic)")
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			} else {
				HStack(spacing: 2) {
					TextField("host", text: Binding(
						get: { forward.remoteHost ?? "" },
						set: { forward.remoteHost = $0.isEmpty ? nil : $0 }
					))
					.frame(maxWidth: 140)
					Text(":")
					TextField("port", value: Binding(
						get: { forward.remotePort ?? 0 },
						set: { forward.remotePort = $0 }
					), format: .number)
					.frame(width: 70)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}

			Toggle("", isOn: $forward.required)
				.labelsHidden()
				.help("If enabled, a bind failure will abort the connection (only when ALL forwards on this host are required).")

			Button {
				onDelete()
			} label: {
				Image(systemName: "xmark")
			}
			.buttonStyle(.borderless)
			.help("Delete this forward")
		}
		.padding(.vertical, 2)
		.overlay(alignment: .leading) {
			let isValid = (try? forward.validate()) != nil
			if !isValid {
				RoundedRectangle(cornerRadius: 4)
					.stroke(.red, lineWidth: 1)
					.padding(-2)
					.help("This forward has invalid settings.")
			}
		}
	}
}
