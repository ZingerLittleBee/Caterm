import CredentialIdentitySecurity
import CredentialIdentityStore
import Foundation
import SSHCommandBuilder
import SwiftUI
import UniformTypeIdentifiers

struct MobileCredentialIdentityListView: View {
	@ObservedObject var store: CredentialIdentityStore
	let materialStore: CredentialIdentityMaterialStore
	let hosts: [SSHHost]
	let triggerSync: @MainActor @Sendable () -> Void

	@State private var editorIdentity: CredentialIdentity?
	@State private var showingAdd = false
	@State private var availability:
		[UUID: CredentialIdentityMaterialAvailability] = [:]
	@State private var availabilityErrors: [UUID: String] = [:]
	@State private var pendingDelete: CredentialIdentity?
	@State private var errorMessage: String?

	var body: some View {
		List {
			if store.identities.isEmpty {
				ContentUnavailableView(
					"No Credential Identities",
					systemImage: "key.horizontal",
					description: Text(
						"Create one credential that can be assigned to multiple Hosts."
					)
				)
			} else {
				ForEach(store.identities) { identity in
					Button {
						editorIdentity = identity
					} label: {
						identityRow(identity)
					}
					.buttonStyle(.plain)
					.swipeActions {
						Button("Delete", role: .destructive) {
							pendingDelete = identity
						}
						if availability[identity.id]
							== .unavailableOnThisDevice {
							Button("Create Here") {
								replaceSecureEnclaveKey(for: identity)
							}
							.tint(.blue)
						}
					}
				}
				if !availabilityErrors.isEmpty {
					Button("Retry Status Checks") {
						Task { await refreshAvailability() }
					}
				}
			}
		}
		.navigationTitle("Credential Identities")
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button {
					showingAdd = true
				} label: {
					Label("Add Identity", systemImage: "plus")
				}
			}
		}
		.task { await refreshAvailability() }
		.onChange(of: store.identities) {
			Task { await refreshAvailability() }
		}
		.sheet(isPresented: $showingAdd) {
			NavigationStack {
				MobileCredentialIdentityEditorView(
					existingIdentity: nil,
					store: store,
					materialStore: materialStore,
					triggerSync: triggerSync
				)
			}
		}
		.sheet(item: $editorIdentity) { identity in
			NavigationStack {
				MobileCredentialIdentityEditorView(
					existingIdentity: identity,
					store: store,
					materialStore: materialStore,
					triggerSync: triggerSync
				)
			}
		}
		.confirmationDialog(
			"Delete credential identity?",
			isPresented: Binding(
				get: { pendingDelete != nil },
				set: { if !$0 { pendingDelete = nil } }
			),
			titleVisibility: .visible
		) {
			Button("Delete", role: .destructive) {
				deletePending()
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text(deleteMessage)
		}
		.alert(
			"Credential Identity Error",
			isPresented: Binding(
				get: { errorMessage != nil },
				set: { if !$0 { errorMessage = nil } }
			),
			presenting: errorMessage
		) { _ in
			Button("OK", role: .cancel) {}
		} message: {
			Text($0)
		}
	}

	private func identityRow(
		_ identity: CredentialIdentity
	) -> some View {
		HStack(spacing: 12) {
			Image(systemName: sourceSymbol(identity.source))
				.frame(width: 28)
				.foregroundStyle(.tint)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 3) {
				Text(identity.name)
					.foregroundStyle(.primary)
				Text("\(identity.username) · \(sourceName(identity.source))")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
			statusLabel(
				availability[identity.id],
				hasError: availabilityErrors[identity.id] != nil
			)
		}
		.contentShape(Rectangle())
		.accessibilityElement(children: .combine)
		.accessibilityLabel(
			"\(identity.name), \(identity.username), \(sourceName(identity.source)), \(statusName(availability[identity.id], hasError: availabilityErrors[identity.id] != nil))"
		)
	}

	@ViewBuilder
	private func statusLabel(
		_ value: CredentialIdentityMaterialAvailability?,
		hasError: Bool
	) -> some View {
		if hasError {
			Button {
				Task { await refreshAvailability() }
			} label: {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(.red)
			}
			.accessibilityLabel("Status check failed. Retry")
		} else {
		switch value {
		case .available:
			Image(systemName: "checkmark.circle.fill")
				.foregroundStyle(.green)
		case .unavailableOnThisDevice:
			Image(systemName: "iphone.slash")
				.foregroundStyle(.orange)
		case .incomplete:
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundStyle(.orange)
		case nil:
			ProgressView().controlSize(.small)
		}
		}
	}

	private var deleteMessage: String {
		guard let identity = pendingDelete else {
			return "This action cannot be undone."
		}
		let count = assignedHostIDs(identity.id).count
		if count > 0 {
			return "This identity is assigned to \(count) Host\(count == 1 ? "" : "s"). Reassign them before deleting it."
		}
		return "The identity and its local secret material will be removed."
	}

	private func assignedHostIDs(_ identityID: UUID) -> Set<UUID> {
		Set(hosts.compactMap {
			$0.credentialIdentity?.identityID == identityID
				? $0.id : nil
		})
	}

	private func deletePending() {
		guard let identity = pendingDelete else { return }
		let assigned = assignedHostIDs(identity.id)
		let assignedMessage = deleteMessage
		pendingDelete = nil
		guard assigned.isEmpty else {
			errorMessage = assignedMessage
			return
		}
		Task { @MainActor in
			do {
				let editor = CredentialIdentityEditorService(
					materialStore: materialStore
				)
				try await editor.delete(
					identity,
					assignedHostIDs: {
						assignedHostIDs(identity.id)
					},
					from: store
				)
				triggerSync()
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}

	private func replaceSecureEnclaveKey(
		for identity: CredentialIdentity
	) {
		guard identity.source.isDeviceBound else { return }
		Task { @MainActor in
			do {
				let editor = CredentialIdentityEditorService(
					materialStore: materialStore
				)
				_ = try await editor.replaceSecureEnclaveKey(
					for: identity,
					originDeviceID: CredentialIdentityDeviceID.current(),
					localizedReason:
						"Create an SSH identity for \(identity.name)",
					in: store
				)
				triggerSync()
				await refreshAvailability()
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}

	private func refreshAvailability() async {
		var next: [UUID: CredentialIdentityMaterialAvailability] = [:]
		var errors: [UUID: String] = [:]
		for identity in store.identities {
			do {
				next[identity.id] = try await materialStore.availability(
					for: identity
				)
			} catch {
				errors[identity.id] = String(describing: error)
			}
		}
		availability = next
		availabilityErrors = errors
	}

	private func sourceName(_ source: CredentialIdentitySource) -> String {
		switch source {
		case .password: "Password"
		case .managedKey: "Private Key"
		case .sshCertificate: "SSH Certificate"
		case .secureEnclaveP256: "Secure Enclave"
		}
	}

	private func sourceSymbol(_ source: CredentialIdentitySource) -> String {
		switch source {
		case .password: "lock"
		case .managedKey: "key.horizontal"
		case .sshCertificate: "checkmark.seal"
		case .secureEnclaveP256: "touchid"
		}
	}

	private func statusName(
		_ value: CredentialIdentityMaterialAvailability?,
		hasError: Bool = false
	) -> String {
		if hasError {
			return "Status check failed"
		}
		return switch value {
		case .available: "Ready"
		case .unavailableOnThisDevice: "Unavailable on this device"
		case .incomplete: "Needs setup"
		case nil: "Checking"
		}
	}
}

private enum MobileCredentialIdentityKind:
	String, CaseIterable, Identifiable {
	case password
	case managedKey
	case sshCertificate
	case secureEnclaveP256

	var id: String { rawValue }

	var title: String {
		switch self {
		case .password: "Password"
		case .managedKey: "Private Key"
		case .sshCertificate: "SSH Certificate"
		case .secureEnclaveP256: "Secure Enclave"
		}
	}
}

private struct MobileCredentialIdentityEditorView: View {
	let existingIdentity: CredentialIdentity?
	let store: CredentialIdentityStore
	let materialStore: CredentialIdentityMaterialStore
	let triggerSync: @MainActor @Sendable () -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var name: String
	@State private var username: String
	@State private var kind: MobileCredentialIdentityKind
	@State private var password = ""
	@State private var passphrase = ""
	@State private var hasPassphrase: Bool
	@State private var privateKey: Data?
	@State private var publicCertificate: Data?
	@State private var privateKeyName: String?
	@State private var certificateName: String?
	@State private var importingPrivateKey = false
	@State private var importingCertificate = false
	@State private var isSaving = false
	@State private var errorMessage: String?

	init(
		existingIdentity: CredentialIdentity?,
		store: CredentialIdentityStore,
		materialStore: CredentialIdentityMaterialStore,
		triggerSync:
			@escaping @MainActor @Sendable () -> Void
	) {
		self.existingIdentity = existingIdentity
		self.store = store
		self.materialStore = materialStore
		self.triggerSync = triggerSync
		_name = State(initialValue: existingIdentity?.name ?? "")
		_username = State(
			initialValue: existingIdentity?.username ?? ""
		)
		let initialKind: MobileCredentialIdentityKind
		let initialPassphrase: Bool
		switch existingIdentity?.source {
		case .password, nil:
			initialKind = .password
			initialPassphrase = false
		case .managedKey(_, let value):
			initialKind = .managedKey
			initialPassphrase = value
		case .sshCertificate(_, let certificate, let value):
			initialKind = .sshCertificate
			initialPassphrase = value
			_publicCertificate = State(initialValue: certificate)
		case .secureEnclaveP256:
			initialKind = .secureEnclaveP256
			initialPassphrase = false
		}
		_kind = State(initialValue: initialKind)
		_hasPassphrase = State(initialValue: initialPassphrase)
	}

	var body: some View {
		Form {
			Section("Identity") {
				TextField("Name", text: $name)
				TextField("Username", text: $username)
					#if os(iOS)
					.textInputAutocapitalization(.never)
					#endif
					.autocorrectionDisabled()
				Picker("Type", selection: $kind) {
					ForEach(MobileCredentialIdentityKind.allCases) {
						Text($0.title).tag($0)
					}
				}
				.disabled(existingIdentity != nil)
			}
			materialSection
		}
		.navigationTitle(
			existingIdentity == nil ? "Add Identity" : "Edit Identity"
		)
		.toolbar {
			ToolbarItem(placement: .cancellationAction) {
				Button("Cancel") { dismiss() }
					.disabled(isSaving)
			}
			ToolbarItem(placement: .confirmationAction) {
				Button(existingIdentity == nil ? "Create" : "Save") {
					save()
				}
				.disabled(!isValid || isSaving)
			}
		}
		.overlay {
			if isSaving {
				ProgressView()
					.padding()
					.background(
						.regularMaterial,
						in: RoundedRectangle(cornerRadius: 12)
					)
			}
		}
		.fileImporter(
			isPresented: $importingPrivateKey,
			allowedContentTypes: [.data],
			allowsMultipleSelection: false,
			onCompletion: importPrivateKey
		)
		.fileImporter(
			isPresented: $importingCertificate,
			allowedContentTypes: [.data],
			allowsMultipleSelection: false,
			onCompletion: importCertificate
		)
		.alert(
			"Could Not Save Identity",
			isPresented: Binding(
				get: { errorMessage != nil },
				set: { if !$0 { errorMessage = nil } }
			),
			presenting: errorMessage
		) { _ in
			Button("OK", role: .cancel) {}
		} message: {
			Text($0)
		}
		.interactiveDismissDisabled(isSaving)
	}

	@ViewBuilder
	private var materialSection: some View {
		switch kind {
		case .password:
			Section("Password") {
				SecureField(
					existingIdentity == nil
						? "Password"
						: "New password (leave blank to keep)",
					text: $password
				)
			}
		case .managedKey:
			keySection(includeCertificate: false)
		case .sshCertificate:
			keySection(includeCertificate: true)
		case .secureEnclaveP256:
			Section("Device-Bound Key") {
				Label(
					"The private key stays in this device's Secure Enclave and requires device authentication.",
					systemImage: "touchid"
				)
				Text(
					"Only its public key and identity metadata sync. On another device, create a local replacement."
				)
				.font(.caption)
				.foregroundStyle(.secondary)
			}
		}
	}

	private func keySection(
		includeCertificate: Bool
	) -> some View {
		Section(
			includeCertificate ? "Certificate Pair" : "Private Key"
		) {
			Button {
				importingPrivateKey = true
			} label: {
				LabeledContent(
					"Private key",
					value: privateKeyName
						?? (existingIdentity == nil
							? "Choose File" : "Keep Existing")
				)
			}
			if includeCertificate {
				Button {
					importingCertificate = true
				} label: {
					LabeledContent(
						"Public certificate",
						value: certificateName
							?? (publicCertificate == nil
								? "Choose File" : "Keep Existing")
					)
				}
			}
			Toggle(
				"Private key has a passphrase",
				isOn: $hasPassphrase
			)
			if hasPassphrase {
				SecureField(
					existingIdentity == nil
						? "Passphrase"
						: "New passphrase (leave blank to keep)",
					text: $passphrase
				)
			}
		}
	}

	private var isValid: Bool {
		guard !name.trimmingCharacters(
			in: .whitespacesAndNewlines
		).isEmpty,
		!username.trimmingCharacters(
			in: .whitespacesAndNewlines
		).isEmpty else {
			return false
		}
		guard existingIdentity == nil else { return true }
		return switch kind {
		case .password:
			!password.isEmpty
		case .managedKey:
			privateKey != nil
				&& (!hasPassphrase || !passphrase.isEmpty)
		case .sshCertificate:
			privateKey != nil
				&& publicCertificate != nil
				&& (!hasPassphrase || !passphrase.isEmpty)
		case .secureEnclaveP256:
			true
		}
	}

	private func save() {
		isSaving = true
		Task { @MainActor in
			defer { isSaving = false }
			do {
				let editor = CredentialIdentityEditorService(
					materialStore: materialStore
				)
				try await editor.save(
					CredentialIdentityEditorInput(
						existingIdentity: existingIdentity,
						kind: kind.sharedKind,
						name: name,
						username: username,
						password: password.isEmpty
							? nil : Data(password.utf8),
						privateKey: privateKey,
						publicCertificate: publicCertificate,
						hasPassphrase: hasPassphrase,
						passphrase: passphrase.isEmpty
							? nil : Data(passphrase.utf8),
						originDeviceID:
							CredentialIdentityDeviceID.current(),
						localizedReason:
							"Create an SSH identity for \(name)"
					),
					to: store
				)
				triggerSync()
				dismiss()
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}

	private func importPrivateKey(
		_ result: Result<[URL], any Error>
	) {
		Task { @MainActor in
			do {
				guard let url = try result.get().first else { return }
				privateKey = try await CredentialIdentityFileImporter.read(url)
				privateKeyName = url.lastPathComponent
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}

	private func importCertificate(
		_ result: Result<[URL], any Error>
	) {
		Task { @MainActor in
			do {
				guard let url = try result.get().first else { return }
				publicCertificate =
					try await CredentialIdentityFileImporter.read(url)
				certificateName = url.lastPathComponent
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}
}


private extension MobileCredentialIdentityKind {
	var sharedKind: CredentialIdentitySecurity.CredentialIdentityEditorKind {
		switch self {
		case .password:
			.password
		case .managedKey:
			.managedKey
		case .sshCertificate:
			.sshCertificate
		case .secureEnclaveP256:
			.secureEnclaveP256
		}
	}
}
