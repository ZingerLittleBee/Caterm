import AppKit
import CredentialIdentityStore
import HostKeyProvisioning
import SessionStore
import SettingsStore
import SnippetStore
import SnippetSyncClient
import SSHCommandBuilder
import SwiftUI

enum HostFormMode {
	case add
	case edit(SSHHost)
}

/// Modal sheet for adding or editing a saved host. Calls
/// `onSubmit(host, secret, keyMaterial)` when the user clicks Save. The
/// optional `secret` is the password (for password auth), the passphrase
/// (for key+passphrase auth), or `nil` for unencrypted-key /
/// edit-without-secret-change. `keyMaterial` is new private-key material
/// to import into managed storage (ADR 0003), or `nil` to keep the host's
/// existing managed key.
///
/// Layout: stacked labels above full-width bordered fields in section cards —
/// deliberately not a grouped `Form` (see docs/adr/0001).
struct HostFormView: View {
	let mode: HostFormMode
	let onSubmit: (SSHHost, String?, PendingKeyMaterial?) -> Void
	let isSubmitting: Bool
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject private var sessionStore: SessionStore
	@EnvironmentObject private var snippetStore: SnippetStore
	@EnvironmentObject private var credentialIdentityStore:
		CredentialIdentityStore

	@State private var label = ""
	@State private var hostname = ""
	@State private var port = "22"
	@State private var username = ""
	@State private var credKind: CredKind = .password
	@State private var pendingKey: PendingKeyMaterial? = nil
	/// Managed key path carried through an edit so "Save without touching
	/// the key" preserves the existing credential. Never user-visible.
	@State private var existingKeyPath: String? = nil
	@State private var hasPassphrase = false
	@State private var pendingSecret = ""
	@State private var credentialIdentityID: UUID?
	@State private var credentialIdentityMigrationState:
		HostCredentialIdentityReference.MigrationState = .confirmed
	@State private var jumpHostSelection = JumpHostSelection.none
	@State private var forwards: [PortForward] = []
	@State private var icon: String? = nil
	@State private var groupText = ""
	@State private var tagsText = ""
	@State private var automationEnabled = false
	@State private var startupSnippetID: UUID?
	@State private var automationEnvironment: [HostEnvironmentVariable] = []
	@State private var automationReviewPolicy: HostAutomationReviewPolicy = .always
	@State private var automationReconnectPolicy: HostAutomationReconnectPolicy = .oncePerSession

	init(
		mode: HostFormMode,
		isSubmitting: Bool = false,
		onSubmit: @escaping (SSHHost, String?, PendingKeyMaterial?) -> Void
	) {
		self.mode = mode
		self.isSubmitting = isSubmitting
		self.onSubmit = onSubmit
	}

	var body: some View {
		let validation = formValidation
		return VStack(spacing: 0) {
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					connectionCard(preview: validation.chainPreview)
					organizationCard
					authenticationCard
					automationCard
					portForwardingCard
					// Theme override only makes sense for an existing host —
					// the override key is the host's UUID, which doesn't exist
					// yet in the `.add` case.
					if case let .edit(host) = mode {
						FormCard("Theme Override") {
							HostThemeOverridePicker(hostId: HostId(host.id.uuidString))
								.labelsHidden()
								.frame(maxWidth: 260, alignment: .leading)
						}
					}
				}
				.textFieldStyle(.roundedBorder)
				.controlSize(.large)
				.padding(20)
			}

			Divider()

			HStack {
				Button("Cancel") { dismiss() }
					.keyboardShortcut(.cancelAction)
					.disabled(isSubmitting)
				Spacer()
				if isSubmitting {
					ProgressView()
						.controlSize(.small)
				}
				Button("Save") { submit() }
					.keyboardShortcut(.defaultAction)
					.disabled(!validation.isValid || isSubmitting)
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 14)
		}
		.frame(width: 560, height: 720)
		.interactiveDismissDisabled(isSubmitting)
		.onAppear { populate() }
	}

	private var automationCard: some View {
		FormCard("Startup Automation") {
			Toggle("Enable automation for new sessions", isOn: $automationEnabled)

			VStack(alignment: .leading, spacing: 5) {
				FieldLabel("Startup snippet")
				HStack {
					Picker("Startup snippet", selection: $startupSnippetID) {
						Text("(none)").tag(nil as UUID?)
						if let startupSnippetID,
						   !snippetStore.snippets.contains(where: {
							$0.id == startupSnippetID
						   }) {
							Text("(deleted snippet)")
								.tag(startupSnippetID as UUID?)
						}
						ForEach(snippetStore.snippets) { snippet in
							Text(snippet.name).tag(snippet.id as UUID?)
						}
					}
					.labelsHidden()
					.frame(maxWidth: .infinity, alignment: .leading)

					if startupSnippetID != nil {
						Button("Remove") {
							startupSnippetID = nil
						}
					}
				}
			}

			if let snippet = selectedStartupSnippet {
				VStack(alignment: .leading, spacing: 6) {
					HStack {
						FieldLabel("Complete command")
						Spacer()
						Text("Runs after the terminal is live")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					ScrollView {
						Text(snippet.content)
							.font(.system(.body, design: .monospaced))
							.textSelection(.enabled)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					.frame(maxHeight: 160)
					.padding(10)
					.background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
					if let placeholders = snippet.placeholders,
					   !placeholders.isEmpty {
						Label(
							"Startup snippets cannot require input: \(placeholders.joined(separator: ", "))",
							systemImage: "exclamationmark.triangle"
						)
						.font(.caption)
						.foregroundStyle(.red)
					}
				}
			} else if startupSnippetID != nil {
				Label(
					"The selected snippet was deleted. Choose another snippet or remove it.",
					systemImage: "exclamationmark.triangle"
				)
				.font(.caption)
				.foregroundStyle(.red)
			}

			Divider()

			VStack(alignment: .leading, spacing: 8) {
				HStack {
					FieldLabel("Remote environment")
					Spacer()
					Button {
						automationEnvironment.append(
							HostEnvironmentVariable(name: "", value: "")
						)
					} label: {
						Label("Add variable", systemImage: "plus")
					}
				}
				if automationEnvironment.isEmpty {
					Text("No environment variables")
						.font(.callout)
						.foregroundStyle(.secondary)
				} else {
					ForEach($automationEnvironment) { $variable in
						HStack(spacing: 8) {
							TextField("NAME", text: $variable.name)
								.font(.system(.body, design: .monospaced))
								.accessibilityLabel("Environment variable name")
							TextField("value", text: $variable.value)
								.font(.system(.body, design: .monospaced))
								.accessibilityLabel(
									"Value for \(variable.name.isEmpty ? "environment variable" : variable.name)"
								)
							Button {
								automationEnvironment.removeAll {
									$0.id == variable.id
								}
							} label: {
								Image(systemName: "trash")
							}
							.buttonStyle(.borderless)
							.accessibilityLabel(
								"Remove \(variable.name.isEmpty ? "environment variable" : variable.name)"
							)
						}
					}
				}
				Text("Values are synchronized as non-secret Host metadata. Do not put passwords, tokens, or private keys here.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}

			HStack(alignment: .top, spacing: 12) {
				VStack(alignment: .leading, spacing: 5) {
					FieldLabel("Before connecting")
					Picker("Before connecting", selection: $automationReviewPolicy) {
						Text("Review before session").tag(HostAutomationReviewPolicy.always)
						Text("Run without review").tag(HostAutomationReviewPolicy.never)
					}
					.labelsHidden()
				}
				VStack(alignment: .leading, spacing: 5) {
					FieldLabel("On reconnect")
					Picker("On reconnect", selection: $automationReconnectPolicy) {
						Text("First connection only")
							.tag(HostAutomationReconnectPolicy.oncePerSession)
						Text("Every connection")
							.tag(HostAutomationReconnectPolicy.everyConnection)
					}
					.labelsHidden()
				}
			}

			if let message = automationValidationMessage {
				Label(message, systemImage: "exclamationmark.circle")
					.font(.caption)
					.foregroundStyle(.red)
			}
		}
	}

	private var selectedStartupSnippet: Snippet? {
		guard let startupSnippetID else { return nil }
		return snippetStore.snippets.first { $0.id == startupSnippetID }
	}

	private var automationDraft: HostAutomation {
		HostAutomation(
			isEnabled: automationEnabled,
			startupSnippetID: startupSnippetID,
			environment: automationEnvironment,
			reviewPolicy: automationReviewPolicy,
			reconnectPolicy: automationReconnectPolicy
		)
	}

	private var automationValidationMessage: String? {
		if automationEnabled, startupSnippetID != nil {
			guard let snippet = selectedStartupSnippet else {
				return "The selected startup snippet is unavailable."
			}
			if let placeholders = snippet.placeholders, !placeholders.isEmpty {
				return "Choose a startup snippet that does not require input."
			}
			if snippet.content.trimmingCharacters(
				in: .whitespacesAndNewlines
			).isEmpty {
				return "The selected startup snippet has no command."
			}
		}
		do {
			_ = try automationDraft.validated()
			return nil
		} catch {
			return (error as? LocalizedError)?.errorDescription
				?? String(describing: error)
		}
	}

	private var organizationCard: some View {
		FormCard("Organization") {
			VStack(alignment: .leading, spacing: 5) {
				FieldLabel("Group")
				TextField(
					"",
					text: $groupText,
					prompt: Text("e.g. Production / API")
				)
				Text("Use / to create a nested group path.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			VStack(alignment: .leading, spacing: 5) {
				FieldLabel("Tags")
				TextField(
					"",
					text: $tagsText,
					prompt: Text("e.g. Linux, Critical, On-call")
				)
				Text("Separate tags with commas.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}

	private func connectionCard(preview: ChainPreviewState) -> some View {
		let eligibleHosts = eligibleJumpHosts
		let displayedSelection = jumpHostSelection.normalized(
			among: sessionStore.hosts
		)
		return FormCard("Connection") {
			HStack(alignment: .top, spacing: 12) {
				VStack(alignment: .leading, spacing: 5) {
					FieldLabel("Label (optional)")
					TextField("", text: $label, prompt: Text("Defaults to user@host"))
				}
				VStack(alignment: .leading, spacing: 5) {
					FieldLabel("Icon")
					HostIconPicker(
						icon: $icon,
						fallbackSymbol: credentialIconFallback
					)
				}
			}
			HStack(alignment: .top, spacing: 12) {
				VStack(alignment: .leading, spacing: 5) {
					FieldLabel("Hostname")
					TextField("", text: $hostname, prompt: Text("e.g. 192.168.1.10"))
				}
				VStack(alignment: .leading, spacing: 5) {
					FieldLabel("Port")
					TextField("", text: $port, prompt: Text("22"))
						.frame(width: 90)
				}
			}
			VStack(alignment: .leading, spacing: 5) {
				FieldLabel("Username")
				TextField("", text: $username, prompt: Text("e.g. root"))
			}
			VStack(alignment: .leading, spacing: 5) {
				FieldLabel("Via host (jump host)")
				Picker("Via host", selection: jumpHostSelectionBinding) {
					Text("(none)").tag(JumpHostSelection.none)
					if displayedSelection.needsPlaceholder(
						among: eligibleHosts
					) {
						Text(displayedSelection.placeholderLabel)
							.tag(displayedSelection)
					}
					ForEach(eligibleHosts, id: \.id) { host in
						Text("\(host.name) (\(host.username)@\(host.hostname))")
							.tag(JumpHostSelection.resolved(localID: host.id))
					}
				}
				.pickerStyle(.menu)
				.labelsHidden()
				.frame(maxWidth: 320, alignment: .leading)
			}
			if let previewText = preview.text {
				Text(previewText)
					.font(.caption)
					.foregroundStyle(preview.isInvalid ? .red : .secondary)
			}
		}
	}

	private var authenticationCard: some View {
		FormCard("Authentication") {
			VStack(alignment: .leading, spacing: 5) {
				FieldLabel("Credential identity")
				Picker(
					"Credential identity",
					selection: $credentialIdentityID
				) {
					Text("Host-owned credential").tag(nil as UUID?)
					if let credentialIdentityID,
					   selectedIdentity == nil {
						Text("(deleted identity)")
							.tag(credentialIdentityID as UUID?)
					}
					ForEach(credentialIdentityStore.identities) {
						Text("\($0.name) · \($0.username)")
							.tag($0.id as UUID?)
					}
				}
				.labelsHidden()
				.frame(maxWidth: .infinity, alignment: .leading)
			}

			if let selectedIdentity {
				LabeledContent("Connect as", value: selectedIdentity.username)
					.accessibilityLabel(
						"Identity username \(selectedIdentity.username)"
					)
				Picker(
					"Migration",
					selection: $credentialIdentityMigrationState
				) {
					Text("Keep host credential as fallback")
						.tag(
							HostCredentialIdentityReference
								.MigrationState.reversible
						)
					Text("Identity only")
						.tag(
							HostCredentialIdentityReference
								.MigrationState.confirmed
						)
				}
				Text(
					credentialIdentityMigrationState == .reversible
						? "The existing host-owned credential remains available until you confirm the migration."
						: "The selected identity is authoritative for new connections."
				)
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}

			DisclosureGroup(
				credentialIdentityID == nil
					? "Host-owned credential"
					: "Host-owned fallback"
			) {
				VStack(alignment: .leading, spacing: 10) {
					Picker("Method", selection: $credKind) {
						ForEach(CredKind.allCases) { kind in
							Text(kind.displayName).tag(kind)
						}
					}
					.pickerStyle(.segmented)
					.labelsHidden()

					AuthMethodFields(
						credKind: $credKind,
						pendingKey: $pendingKey,
						hasPassphrase: $hasPassphrase,
						pendingSecret: $pendingSecret,
						hasExistingManagedKey: existingKeyPath != nil
					)
					.frame(minHeight: 96, alignment: .top)
				}
				.padding(.top, 8)
			}
		}
	}

	private var selectedIdentity: CredentialIdentity? {
		guard let credentialIdentityID else { return nil }
		return credentialIdentityStore.identity(id: credentialIdentityID)
	}

	private var portForwardingCard: some View {
		FormCard("Port Forwarding") {
			if forwards.isEmpty {
				Text("No port forwards")
					.font(.callout)
					.foregroundStyle(.secondary)
			} else {
				ForEach($forwards) { $forward in
					PortForwardRuleEditor(
						forward: $forward,
						onDelete: { deleteForward(forward.id) }
					)
				}
			}
			Button {
				addForward()
			} label: {
				Label("Add port forward", systemImage: "plus")
			}
		}
	}

	private struct FormValidation {
		let chainPreview: ChainPreviewState
		let isValid: Bool
	}

	private var formValidation: FormValidation {
		let resolution = selectedChainResolution
		let fieldsAreValid = !hostname.isEmpty
			&& !username.isEmpty
			&& (credentialIdentityID == nil || selectedIdentity != nil)
			&& (
				credentialIdentityID != nil
					|| credKind != .keyFile
					|| pendingKey != nil
					|| existingKeyPath != nil
			)
			&& (Int(port).map { (1...65535).contains($0) } ?? false)
		let forwardsAreValid = (try? PortForward.validateCollection(forwards)) != nil
		return FormValidation(
			chainPreview: chainPreview(for: resolution),
			isValid: fieldsAreValid
				&& resolution.isComplete
				&& forwardsAreValid
				&& automationValidationMessage == nil
		)
	}

	enum UnresolvedJumpHostReference: Hashable {
		case localID(UUID)
		case serverID(String)
		case localAndServer(localID: UUID, serverID: String)
	}

	enum JumpHostSelection: Hashable {
		case none
		case resolved(localID: UUID)
		case unresolved(UnresolvedJumpHostReference)

		struct Reference: Equatable {
			let localID: UUID?
			let serverID: String?
		}

		func normalized(among hosts: [SSHHost]) -> JumpHostSelection {
			switch self {
			case .none, .resolved:
				return self
			case .unresolved(.localID(let localID)):
				guard hosts.contains(where: { $0.id == localID }) else { return self }
				return .resolved(localID: localID)
			case .unresolved(.serverID(let serverID)):
				guard let parent = hosts.first(where: { $0.serverId == serverID }) else {
					return self
				}
				return .resolved(localID: parent.id)
			case .unresolved(.localAndServer(let localID, let serverID)):
				if hosts.contains(where: { $0.id == localID }) {
					return .resolved(localID: localID)
				}
				guard let parent = hosts.first(where: { $0.serverId == serverID }) else {
					return self
				}
				return .resolved(localID: parent.id)
			}
		}

		func reference(among hosts: [SSHHost]) -> Reference {
			switch normalized(among: hosts) {
			case .none:
				return Reference(localID: nil, serverID: nil)
			case .resolved(let localID):
				let serverID = hosts.first(where: { $0.id == localID })?.serverId
				return Reference(localID: localID, serverID: serverID)
			case .unresolved(.localID(let localID)):
				return Reference(localID: localID, serverID: nil)
			case .unresolved(.serverID(let serverID)):
				return Reference(localID: nil, serverID: serverID)
			case .unresolved(.localAndServer(let localID, let serverID)):
				return Reference(localID: localID, serverID: serverID)
			}
		}

		func needsPlaceholder(among hosts: [SSHHost]) -> Bool {
			switch self {
			case .none:
				return false
			case .unresolved:
				return true
			case .resolved(let localID):
				return !hosts.contains(where: { $0.id == localID })
			}
		}

		var placeholderLabel: String {
			switch self {
			case .unresolved:
				return "(deleted host)"
			case .resolved:
				return "(invalid jump host)"
			case .none:
				return "(none)"
			}
		}
	}

	private var jumpHostSelectionBinding: Binding<JumpHostSelection> {
		Binding(
			get: { jumpHostSelection.normalized(among: sessionStore.hosts) },
			set: { jumpHostSelection = $0 }
		)
	}

	private enum ChainPreviewState {
		case none
		case valid(names: [String])
		case invalid(names: [String])

		var text: String? {
			switch self {
			case .none:
				return nil
			case .valid(let names), .invalid(let names):
				return "Will connect via \(names.joined(separator: " → "))"
			}
		}

		var isInvalid: Bool {
			if case .invalid = self { return true }
			return false
		}
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

	private func chainPreview(for resolution: ChainResolution) -> ChainPreviewState {
		guard jumpHostSelection != .none else { return .none }
		var names = resolution.ancestors.map(\.name)
		switch resolution.diagnostic {
		case .none:
			return .valid(names: names)
		case .missing:
			names.append("(deleted)")
			return .invalid(names: names)
		case .cycle:
			names.append("(cycle)")
			return .invalid(names: names)
		}
	}

	private var selectedChainResolution: ChainResolution {
		let reference = jumpHostSelection.reference(among: sessionStore.hosts)
		var draft = HostFormView.buildHost(
			mode: mode,
			name: resolvedName,
			hostname: hostname,
			port: Int(port) ?? 22,
			username: username,
			credential: formCredentialSource
		)
		draft.jumpHostId = reference.localID
		draft.jumpHostServerId = reference.serverID
		return ChainResolver(hosts: sessionStore.hosts).resolve(draft)
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
			existingKeyPath = p
			hasPassphrase = hp
		case .agent:
			// Legacy `.agent` hosts (agent auth was removed in v1.7 — it
			// never worked in a Finder-launched .app). Surface as Password
			// so the user can reconfigure with a method that works.
			credKind = .password
		}
		jumpHostSelection = Self.jumpHostSelectionForForm(
			host: host,
			allHosts: sessionStore.hosts
		)
		forwards = host.forwards
		icon = host.icon
		groupText = HostOrganizationText.groupText(host.organization)
		tagsText = HostOrganizationText.tagsText(host.organization)
		automationEnabled = host.automation.isEnabled
		startupSnippetID = host.automation.startupSnippetID
		automationEnvironment = host.automation.environment
		automationReviewPolicy = host.automation.reviewPolicy
		automationReconnectPolicy = host.automation.reconnectPolicy
		credentialIdentityID = host.credentialIdentity?.identityID
		credentialIdentityMigrationState =
			host.credentialIdentity?.migrationState ?? .confirmed
	}

	/// Credential as it should be persisted on the host. For a brand-new
	/// key the managed path doesn't exist yet — the parent's provisioning
	/// step rewrites `keyPath` to the managed location after import, so
	/// the placeholder here is never what ends up on disk.
	private var formCredentialSource: CredentialSource {
		switch credKind {
		case .password: return .password
		case .keyFile:  return .keyFile(keyPath: existingKeyPath ?? "",
		                                hasPassphrase: hasPassphrase)
		}
	}

	private func submit() {
		let cred = formCredentialSource
		let jumpHostReference = jumpHostSelection.reference(among: sessionStore.hosts)
		var host = HostFormView.buildHost(
			mode: mode,
			name: resolvedName,
			hostname: hostname,
			port: Int(port) ?? 22,
			username: username,
			credential: cred
		)
		host.jumpHostId = jumpHostReference.localID
		host.jumpHostServerId = jumpHostReference.serverID
		host.forwards = forwards
		host.icon = icon
		host.organization = HostOrganizationText.makeOrganization(
			group: groupText, tags: tagsText
		)
		host.automation = automationDraft
		host.credentialIdentity = credentialIdentityID.map {
			HostCredentialIdentityReference(
				identityID: $0,
				migrationState: credentialIdentityMigrationState
			)
		}
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
		onSubmit(host, secret, credKind == .keyFile ? pendingKey : nil)
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

	static func jumpHostSelectionForForm(
		host: SSHHost,
		allHosts: [SSHHost]
	) -> JumpHostSelection {
		if let jumpHostId = host.jumpHostId,
		   let localParent = allHosts.first(where: { $0.id == jumpHostId }) {
			return .resolved(localID: localParent.id)
		}
		if let jumpHostServerId = host.jumpHostServerId,
		   let serverParent = allHosts.first(where: { $0.serverId == jumpHostServerId }) {
			return .resolved(localID: serverParent.id)
		}
		switch (host.jumpHostId, host.jumpHostServerId) {
		case (.none, .none):
			return .none
		case (.some(let localID), .none):
			return .unresolved(.localID(localID))
		case (.none, .some(let serverID)):
			return .unresolved(.serverID(serverID))
		case (.some(let localID), .some(let serverID)):
			return .unresolved(.localAndServer(
				localID: localID,
				serverID: serverID
			))
		}
	}
}

/// Titled section card: the host form's replacement for `Form` sections
/// (ADR 0001). Content is stacked with a consistent gutter.
private struct FormCard<Content: View>: View {
	let title: String
	@ViewBuilder let content: Content

	init(_ title: String, @ViewBuilder content: () -> Content) {
		self.title = title
		self.content = content()
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(title).font(.headline)
			content
		}
		.padding(16)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
	}
}

/// One port-forward rule as a labelled mini-card: kind + required + delete
/// in the header, then per-field labelled inputs, then the plain-language
/// explanation. Invalid rules get a red border.
struct PortForwardRuleEditor: View {
	@Binding var forward: PortForward
	let onDelete: () -> Void

	/// One-line, jargon-free description of what this rule does, kept in
	/// sync with the entered values so the user sees the effect at a glance.
	private var explanation: String {
		let bindHost = forward.bindAddress?.isEmpty == false
			? forward.bindAddress ?? "localhost"
			: "localhost"
		let bind = "\(bindHost):\(forward.bindPort)"
		let host = forward.remoteHost?.isEmpty == false
			? forward.remoteHost ?? "localhost"
			: "localhost"
		let rport = forward.remotePort ?? forward.bindPort
		switch forward.kind {
		case .local:
			return "Opens \(bind) on this Mac → reaches \(host):\(rport) through the server."
		case .remote:
			return "Opens \(bind) on the server → tunnels back to \(host):\(rport) on this Mac."
		case .dynamic:
			return "Runs a SOCKS proxy on \(bind) of this Mac (route apps through the server)."
		}
	}

	private var typeHelp: String {
		"""
		Local port: open a port on your Mac that reaches a service the server can see.
		Remote port: open a port on the server that tunnels back to your Mac.
		SOCKS proxy: a dynamic proxy on your Mac that routes traffic via the server.
		"""
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				Picker("", selection: $forward.kind) {
					Text("Local port").tag(PortForward.Kind.local)
					Text("Remote port").tag(PortForward.Kind.remote)
					Text("SOCKS proxy").tag(PortForward.Kind.dynamic)
				}
				.pickerStyle(.menu)
				.labelsHidden()
				.fixedSize()
				.help(typeHelp)
				.onChange(of: forward.kind) { _, newKind in
					if newKind == .dynamic {
						forward.remoteHost = nil
						forward.remotePort = nil
					} else if forward.remoteHost == nil {
						forward.remoteHost = "localhost"
						forward.remotePort = forward.bindPort
					}
				}

				Spacer()

				Toggle("Required", isOn: $forward.required)
					.toggleStyle(.checkbox)
					.help("Required: if this port can't be opened, abort the whole connection (only when every forward on this host is required).")

				Button {
					onDelete()
				} label: {
					Image(systemName: "trash")
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.borderless)
				.help("Remove this rule")
			}

			HStack(alignment: .top, spacing: 10) {
				VStack(alignment: .leading, spacing: 4) {
					FieldLabel("Label (optional)")
					TextField("", text: Binding(
						get: { forward.label ?? "" },
						set: { forward.label = $0.isEmpty ? nil : $0 }
					), prompt: Text("e.g. PostgreSQL"))
				}
				VStack(alignment: .leading, spacing: 4) {
					FieldLabel("Bind address")
					TextField("", text: Binding(
						get: { forward.bindAddress ?? "" },
						set: { forward.bindAddress = $0.isEmpty ? nil : $0 }
					), prompt: Text("localhost"))
					.frame(width: 140)
					.help("Leave empty to bind on the SSH default loopback address.")
				}
			}

			HStack(alignment: .bottom, spacing: 10) {
				VStack(alignment: .leading, spacing: 4) {
					FieldLabel("Port to open")
					TextField("", value: $forward.bindPort,
					          format: .number.grouping(.never),
					          prompt: Text("8080"))
						.frame(width: 90)
						.help("The port number to open.")
				}

				if forward.kind != .dynamic {
					Image(systemName: "arrow.right")
						.font(.caption)
						.foregroundStyle(.secondary)
						.padding(.bottom, 7)

					VStack(alignment: .leading, spacing: 4) {
						FieldLabel("Destination host")
						TextField("", text: Binding(
							get: { forward.remoteHost ?? "" },
							set: { forward.remoteHost = $0.isEmpty ? nil : $0 }
						), prompt: Text("localhost"))
						.help("The destination host, as seen from the other side.")
					}

					VStack(alignment: .leading, spacing: 4) {
						FieldLabel("Destination port")
						TextField("", value: Binding(
							get: { forward.remotePort ?? 0 },
							set: { forward.remotePort = $0 }
						), format: .number.grouping(.never),
						   prompt: Text("80"))
						.frame(width: 90)
						.help("The destination port.")
					}
				} else {
					Spacer(minLength: 0)
				}
			}

			Text(explanation)
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(12)
		.background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
		.overlay {
			let isValid = (try? forward.validate()) != nil
			if !isValid {
				RoundedRectangle(cornerRadius: 8)
					.stroke(.red, lineWidth: 1)
					.help("This rule has invalid settings — check the port numbers and host.")
			}
		}
	}
}
