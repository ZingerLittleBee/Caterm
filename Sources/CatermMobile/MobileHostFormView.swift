import SnippetSyncClient
import SSHCommandBuilder
import SwiftUI

struct MobileHostFormView: View {
	let mode: MobileHostFormMode
	let allHosts: [SSHHost]
	let snippets: [Snippet]
	let onSave: (MobileHostDraftPayload) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var draft: MobileHostDraft
	@State private var validationError: MobileHostDraft.ValidationError?

	init(
		mode: MobileHostFormMode,
		allHosts: [SSHHost],
		snippets: [Snippet] = [],
		onSave: @escaping (MobileHostDraftPayload) -> Void
	) {
		self.mode = mode
		self.allHosts = allHosts
		self.snippets = snippets
		self.onSave = onSave
		switch mode {
		case .add:
			_draft = State(initialValue: MobileHostDraft())
		case .edit(let host):
			var initial = MobileHostDraft(host: host)
			// Agent auth is no longer offered on mobile; surface such a
			// host as Password so the form stays consistent.
			if initial.credential == .agent {
				initial.credential = .password(secret: "")
			}
			_draft = State(initialValue: initial)
		}
	}

	var body: some View {
		Form {
			Section("Host") {
				TextField("Label", text: $draft.label)
				TextField("Hostname", text: $draft.hostname)
					.sshFieldStyle()
				TextField("Port", text: $draft.port)
					.sshFieldStyle(numeric: true)
				TextField("Username", text: $draft.username)
					.sshFieldStyle()
			}

			Section("Credentials") {
				Picker("Method", selection: credentialKind) {
					Text("Password").tag(MobileCredentialKind.password)
					Text("Key File").tag(MobileCredentialKind.keyFile)
				}

				switch draft.credential {
				case .password:
					SecureField("Password", text: passwordSecret)
						.sshFieldStyle()
				case .keyFile:
					TextField("Private key path", text: keyPath)
						.sshFieldStyle()
					Toggle("Has passphrase", isOn: keyHasPassphrase)
					if keyHasPassphrase.wrappedValue {
						SecureField("Passphrase", text: keySecret)
					}
				case .agent:
					EmptyView()
				}
			}

			Section("Startup Automation") {
				Toggle(
					"Enable for new sessions",
					isOn: $draft.automation.isEnabled
				)

				Picker(
					"Startup snippet",
					selection: $draft.automation.startupSnippetID
				) {
					Text("None").tag(nil as UUID?)
					if let selected = draft.automation.startupSnippetID,
					   !snippets.contains(where: { $0.id == selected }) {
						Text("Deleted snippet").tag(selected as UUID?)
					}
					ForEach(snippets) { snippet in
						Text(snippet.name).tag(snippet.id as UUID?)
					}
				}

				if draft.automation.startupSnippetID != nil {
					Button("Remove Startup Snippet", role: .destructive) {
						draft.automation.startupSnippetID = nil
					}
				}

				if let snippet = selectedSnippet {
					VStack(alignment: .leading, spacing: 6) {
						Text("Complete Command")
							.font(.caption)
							.foregroundStyle(.secondary)
						Text(snippet.content)
							.font(.system(.body, design: .monospaced))
							.textSelection(.enabled)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					if let placeholders = snippet.placeholders,
					   !placeholders.isEmpty {
						Label(
							"Requires input: \(placeholders.joined(separator: ", "))",
							systemImage: "exclamationmark.triangle"
						)
						.font(.caption)
						.foregroundStyle(.red)
					}
				} else if draft.automation.startupSnippetID != nil {
					Label(
						"The selected snippet is unavailable.",
						systemImage: "exclamationmark.triangle"
					)
					.font(.caption)
					.foregroundStyle(.red)
				}

				if draft.automation.environment.isEmpty {
					Text("No remote environment variables")
						.foregroundStyle(.secondary)
				}
				ForEach($draft.automation.environment) { $variable in
					VStack(alignment: .leading, spacing: 8) {
						TextField("Variable name", text: $variable.name)
							.sshFieldStyle()
							.font(.system(.body, design: .monospaced))
						TextField("Value", text: $variable.value)
							.sshFieldStyle()
							.font(.system(.body, design: .monospaced))
						Button("Remove Variable", role: .destructive) {
							draft.automation.environment.removeAll {
								$0.id == variable.id
							}
						}
					}
				}
				Button {
					draft.automation.environment.append(
						HostEnvironmentVariable(name: "", value: "")
					)
				} label: {
					Label("Add Environment Variable", systemImage: "plus")
				}

				Picker(
					"Before connecting",
					selection: $draft.automation.reviewPolicy
				) {
					Text("Review before session")
						.tag(HostAutomationReviewPolicy.always)
					Text("Run without review")
						.tag(HostAutomationReviewPolicy.never)
				}

				Picker(
					"On reconnect",
					selection: $draft.automation.reconnectPolicy
				) {
					Text("First connection only")
						.tag(HostAutomationReconnectPolicy.oncePerSession)
					Text("Every connection")
						.tag(HostAutomationReconnectPolicy.everyConnection)
				}

				Text("Environment values sync as non-secret Host metadata. Do not enter passwords, tokens, or private keys.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.navigationTitle(title)
		#if os(iOS)
		.safeAreaInset(edge: .bottom, spacing: 0) {
			HStack {
				Button("Cancel") { dismiss() }
				Spacer()
				Button("Save", action: save)
					.buttonStyle(.borderedProminent)
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
			.background(.bar)
		}
		#else
		.toolbar {
			ToolbarItem(placement: .cancellationAction) {
				Button("Cancel") { dismiss() }
			}
			ToolbarItem(placement: .confirmationAction) {
				Button("Save", action: save)
			}
		}
		#endif
		.alert("Invalid Host", isPresented: errorIsPresented) {
			Button("OK") { validationError = nil }
		} message: {
			Text(validationMessage)
		}
	}

	private var title: String {
		switch mode {
		case .add: "Add Host"
		case .edit: "Edit Host"
		}
	}

	private func save() {
		do {
			if let issue = startupSnippetIssue {
				throw MobileHostDraft.ValidationError.invalidAutomation(issue)
			}
			let payload = try draft.build(mode: mode, allHosts: allHosts)
			onSave(payload)
			dismiss()
		} catch let error as MobileHostDraft.ValidationError {
			validationError = error
		} catch {
			validationError = .missingHostname
		}
	}

	private var selectedSnippet: Snippet? {
		guard let id = draft.automation.startupSnippetID else { return nil }
		return snippets.first { $0.id == id }
	}

	private var startupSnippetIssue: String? {
		guard draft.automation.isEnabled,
		      draft.automation.startupSnippetID != nil else {
			return nil
		}
		guard let snippet = selectedSnippet else {
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
		return nil
	}

	private var credentialKind: Binding<MobileCredentialKind> {
		Binding {
			switch draft.credential {
			case .password: .password
			case .keyFile: .keyFile
			case .agent: .password
			}
		} set: { kind in
			switch kind {
			case .password:
				draft.credential = .password(secret: "")
			case .keyFile:
				draft.credential = .keyFile(path: "", hasPassphrase: false, secret: "")
			}
		}
	}

	private var passwordSecret: Binding<String> {
		Binding {
			if case .password(let secret) = draft.credential { return secret }
			return ""
		} set: { value in
			draft.credential = .password(secret: value)
		}
	}

	private var keyPath: Binding<String> {
		Binding {
			if case .keyFile(let path, _, _) = draft.credential { return path }
			return ""
		} set: { value in
			if case .keyFile(_, let hasPassphrase, let secret) = draft.credential {
				draft.credential = .keyFile(path: value, hasPassphrase: hasPassphrase, secret: secret)
			}
		}
	}

	private var keyHasPassphrase: Binding<Bool> {
		Binding {
			if case .keyFile(_, let hasPassphrase, _) = draft.credential { return hasPassphrase }
			return false
		} set: { value in
			if case .keyFile(let path, _, let secret) = draft.credential {
				draft.credential = .keyFile(path: path, hasPassphrase: value, secret: secret)
			}
		}
	}

	private var keySecret: Binding<String> {
		Binding {
			if case .keyFile(_, _, let secret) = draft.credential { return secret }
			return ""
		} set: { value in
			if case .keyFile(let path, let hasPassphrase, _) = draft.credential {
				draft.credential = .keyFile(path: path, hasPassphrase: hasPassphrase, secret: value)
			}
		}
	}

	private var errorIsPresented: Binding<Bool> {
		Binding {
			validationError != nil
		} set: { isPresented in
			if !isPresented { validationError = nil }
		}
	}

	private var validationMessage: String {
		switch validationError {
		case .missingHostname:
			"Hostname is required."
		case .missingUsername:
			"Username is required."
		case .invalidPort:
			"Port must be between 1 and 65535."
		case .missingKeyPath:
			"Private key path is required."
		case .invalidAutomation(let message):
			message
		case nil:
			"Check the host details and try again."
		}
	}
}

private enum MobileCredentialKind: Hashable {
	case password
	case keyFile
}

private extension View {
	/// SSH connection fields are case-sensitive identifiers, not prose:
	/// never autocapitalize or autocorrect them.
	@ViewBuilder
	func sshFieldStyle(numeric: Bool = false) -> some View {
		#if os(iOS)
		self
			.textInputAutocapitalization(.never)
			.autocorrectionDisabled()
			.keyboardType(numeric ? .numberPad : .asciiCapable)
		#else
		self.autocorrectionDisabled()
		#endif
	}
}
