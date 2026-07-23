import CredentialIdentitySecurity
import CredentialIdentityStore
import Foundation
import ManagedKeyStore
import SessionStore
import SSHCommandBuilder
import SwiftUI
import UniformTypeIdentifiers

private struct CredentialIdentityRow: Identifiable {
	let identity: CredentialIdentity
	let availability: CredentialIdentityMaterialAvailability?

	var id: UUID { identity.id }
	var name: String { identity.name }
	var username: String { identity.username }
	var source: String {
		switch identity.source {
		case .password:
			"Password"
		case .managedKey:
			"Private key"
		case .sshCertificate:
			"SSH certificate"
		case .secureEnclaveP256:
			"Secure Enclave"
		}
	}
	var status: String {
		switch availability {
		case .available:
			"Ready"
		case .unavailableOnThisDevice:
			"Unavailable on this Mac"
		case .incomplete:
			"Needs setup"
		case nil:
			"Checking…"
		}
	}
}

private enum CredentialIdentityEditorRequest: Identifiable {
	case add
	case edit(UUID)

	var id: String {
		switch self {
		case .add:
			"add"
		case .edit(let id):
			"edit-\(id.uuidString)"
		}
	}
}

private struct CredentialIdentityTable: View {
	let rows: [CredentialIdentityRow]
	@Binding var selection: Set<UUID>
	@Binding var sortOrder: [KeyPathComparator<CredentialIdentityRow>]
	let onDelete: () -> Void

	var body: some View {
		Table(
			rows,
			selection: $selection,
			sortOrder: $sortOrder
		) {
			TableColumn("Name", value: \.name)
				.width(min: 120, ideal: 170)
			TableColumn("Username", value: \.username)
				.width(min: 100, ideal: 130)
			TableColumn("Type", value: \.source)
				.width(min: 100, ideal: 130)
			TableColumn("Status", value: \.status) { row in
				Label(
					row.status,
					systemImage: statusSymbol(row.availability)
				)
				.foregroundStyle(
					row.availability == .available
						? Color.secondary : Color.orange
				)
			}
			.width(min: 130, ideal: 170)
		}
		.frame(minHeight: 190, idealHeight: 230)
		.overlay {
			if rows.isEmpty {
				ContentUnavailableView(
					"No Credential Identities",
					systemImage: "key.horizontal",
					description: Text(
						"Create an identity to reuse a password, key, certificate, or device-bound key."
					)
				)
			}
		}
		.onDeleteCommand(perform: onDelete)
	}

	private func statusSymbol(
		_ status: CredentialIdentityMaterialAvailability?
	) -> String {
		switch status {
		case .available:
			"checkmark.circle.fill"
		case .unavailableOnThisDevice:
			"laptopcomputer.slash"
		case .incomplete:
			"exclamationmark.triangle.fill"
		case nil:
			"clock"
		}
	}
}

struct CredentialIdentityManagementView: View {
	@ObservedObject var store: CredentialIdentityStore
	let materialStore: CredentialIdentityMaterialStore
	@ObservedObject var sessionStore: SessionStore
	let triggerSync: @MainActor () -> Void

	@State private var selection: Set<UUID> = []
	@State private var sortOrder = [
		KeyPathComparator(\CredentialIdentityRow.name)
	]
	@State private var availability:
		[UUID: CredentialIdentityMaterialAvailability] = [:]
	@State private var editorRequest: CredentialIdentityEditorRequest?
	@State private var pendingDeleteID: UUID?
	@State private var errorMessage: String?
	@State private var isWorking = false

	private var rows: [CredentialIdentityRow] {
		store.identities.map {
			CredentialIdentityRow(
				identity: $0,
				availability: availability[$0.id]
			)
		}.sorted(using: sortOrder)
	}

	private var selectedIdentity: CredentialIdentity? {
		guard selection.count == 1, let id = selection.first else {
			return nil
		}
		return store.identity(id: id)
	}

	private var selectedNeedsLocalReplacement: Bool {
		guard let selectedIdentity,
		      selectedIdentity.source.isDeviceBound else {
			return false
		}
		return availability[selectedIdentity.id] == .unavailableOnThisDevice
	}

	var body: some View {
		Section("Reusable Identities") {
			VStack(alignment: .leading, spacing: 10) {
				Text(
					"Assign one credential to multiple hosts. Identity changes apply to new connections; open sessions keep their original snapshot."
				)
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

				CredentialIdentityTable(
					rows: rows,
					selection: $selection,
					sortOrder: $sortOrder,
					onDelete: {
						pendingDeleteID = selectedIdentity?.id
					}
				)

				HStack(spacing: 8) {
					Button {
						editorRequest = .add
					} label: {
						Label("Add", systemImage: "plus")
					}
					.keyboardShortcut("n", modifiers: [.command, .option])

					Button {
						if let id = selectedIdentity?.id {
							editorRequest = .edit(id)
						}
					} label: {
						Label("Edit", systemImage: "pencil")
					}
					.disabled(selectedIdentity == nil || isWorking)

					if selectedNeedsLocalReplacement {
						Button {
							replaceSecureEnclaveKey()
						} label: {
							Label(
								"Create Key on This Mac",
								systemImage: "touchid"
							)
						}
						.disabled(isWorking)
					}

					Spacer()

					Button(role: .destructive) {
						pendingDeleteID = selectedIdentity?.id
					} label: {
						Label("Delete", systemImage: "trash")
					}
					.disabled(selectedIdentity == nil || isWorking)
				}
			}
		}
		.task {
			await refreshAvailability()
		}
		.onChange(of: store.identities) {
			selection.formIntersection(Set(store.identities.map(\.id)))
			Task { await refreshAvailability() }
		}
		.sheet(item: $editorRequest) { request in
			CredentialIdentityEditorSheet(
				existingIdentity: identity(for: request),
				store: store,
				materialStore: materialStore,
				triggerSync: triggerSync
			)
		}
		.confirmationDialog(
			"Delete credential identity?",
			isPresented: Binding(
				get: { pendingDeleteID != nil },
				set: { if !$0 { pendingDeleteID = nil } }
			),
			titleVisibility: .visible
		) {
			Button("Delete", role: .destructive) {
				deletePendingIdentity()
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
			Button("OK") { errorMessage = nil }
		} message: {
			Text($0)
		}
	}

	private var deleteMessage: String {
		guard let id = pendingDeleteID else {
			return "This action cannot be undone."
		}
		let count = assignedHostIDs(identityID: id).count
		if count > 0 {
			return "This identity is assigned to \(count) host\(count == 1 ? "" : "s"). Reassign those hosts before deleting it."
		}
		return "The identity and its local secret material will be removed. This action cannot be undone."
	}

	private func identity(
		for request: CredentialIdentityEditorRequest
	) -> CredentialIdentity? {
		switch request {
		case .add:
			nil
		case .edit(let id):
			store.identity(id: id)
		}
	}

	private func assignedHostIDs(identityID: UUID) -> Set<UUID> {
		Set(sessionStore.hosts.compactMap { host in
			host.credentialIdentity?.identityID == identityID
				? host.id : nil
		})
	}

	private func refreshAvailability() async {
		var next: [UUID: CredentialIdentityMaterialAvailability] = [:]
		for identity in store.identities {
			next[identity.id] = try? await materialStore.availability(
				for: identity
			)
		}
		availability = next
	}

	private func deletePendingIdentity() {
		guard let id = pendingDeleteID,
		      let identity = store.identity(id: id) else {
			pendingDeleteID = nil
			return
		}
		pendingDeleteID = nil
		let hostIDs = assignedHostIDs(identityID: id)
		guard hostIDs.isEmpty else {
			errorMessage = deleteMessage
			return
		}
		isWorking = true
		Task { @MainActor in
			defer { isWorking = false }
			do {
				let previous = try await materialStore.snapshot(for: identity)
				try await materialStore.delete(identity: identity)
				do {
					try store.delete(id: id, assignedHostIDs: hostIDs)
				} catch {
					if previous.hasAnyMaterial {
						try? await materialStore.replaceMaterial(
							for: identity,
							with: previous
						)
					}
					throw error
				}
				selection.remove(id)
				triggerSync()
			} catch {
				errorMessage = String(describing: error)
			}
		}
	}

	private func replaceSecureEnclaveKey() {
		guard let identity = selectedIdentity,
		      identity.source.isDeviceBound else { return }
		isWorking = true
		Task { @MainActor in
			defer { isWorking = false }
			do {
				let generated = try await materialStore
					.createSecureEnclaveIdentity(
						name: identity.name,
						username: identity.username,
						originDeviceID:
							CredentialIdentityDeviceID.current(),
						localizedReason:
							"Create an SSH identity for \(identity.name)"
					)
				var replacement = identity
				replacement.source = generated.source
				do {
					try store.upsert(replacement)
				} catch {
					try? await materialStore.delete(identity: generated)
					throw error
				}
				try? await materialStore.delete(identity: identity)
				triggerSync()
				await refreshAvailability()
			} catch {
				errorMessage = String(describing: error)
			}
		}
	}
}

private enum CredentialIdentityEditorKind: String, CaseIterable, Identifiable {
	case password
	case managedKey
	case sshCertificate
	case secureEnclaveP256

	var id: String { rawValue }
	var title: String {
		switch self {
		case .password:
			"Password"
		case .managedKey:
			"Private Key"
		case .sshCertificate:
			"SSH Certificate"
		case .secureEnclaveP256:
			"Secure Enclave"
		}
	}
}

private struct CredentialIdentityEditorSheet: View {
	let existingIdentity: CredentialIdentity?
	let store: CredentialIdentityStore
	let materialStore: CredentialIdentityMaterialStore
	let triggerSync: @MainActor () -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var name: String
	@State private var username: String
	@State private var kind: CredentialIdentityEditorKind
	@State private var password = ""
	@State private var passphrase = ""
	@State private var hasPassphrase: Bool
	@State private var privateKey: Data?
	@State private var publicCertificate: Data?
	@State private var privateKeyFileName: String?
	@State private var certificateFileName: String?
	@State private var importingPrivateKey = false
	@State private var importingCertificate = false
	@State private var isSaving = false
	@State private var errorMessage: String?

	init(
		existingIdentity: CredentialIdentity?,
		store: CredentialIdentityStore,
		materialStore: CredentialIdentityMaterialStore,
		triggerSync: @escaping @MainActor () -> Void
	) {
		self.existingIdentity = existingIdentity
		self.store = store
		self.materialStore = materialStore
		self.triggerSync = triggerSync
		_name = State(initialValue: existingIdentity?.name ?? "")
		_username = State(initialValue: existingIdentity?.username ?? "")
		let sourceKind: CredentialIdentityEditorKind
		let sourceHasPassphrase: Bool
		switch existingIdentity?.source {
		case .password, nil:
			sourceKind = .password
			sourceHasPassphrase = false
		case .managedKey(_, let value):
			sourceKind = .managedKey
			sourceHasPassphrase = value
		case .sshCertificate(_, let certificate, let value):
			sourceKind = .sshCertificate
			sourceHasPassphrase = value
			_publicCertificate = State(initialValue: certificate)
		case .secureEnclaveP256:
			sourceKind = .secureEnclaveP256
			sourceHasPassphrase = false
		}
		_kind = State(initialValue: sourceKind)
		_hasPassphrase = State(initialValue: sourceHasPassphrase)
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
		if existingIdentity != nil {
			return true
		}
		switch kind {
		case .password:
			return !password.isEmpty
		case .managedKey:
			return privateKey != nil
				&& (!hasPassphrase || !passphrase.isEmpty)
		case .sshCertificate:
			return privateKey != nil
				&& publicCertificate != nil
				&& (!hasPassphrase || !passphrase.isEmpty)
		case .secureEnclaveP256:
			return true
		}
	}

	var body: some View {
		VStack(spacing: 0) {
			Form {
				Section("Identity") {
					TextField("Name", text: $name)
					TextField("Username", text: $username)
					Picker("Type", selection: $kind) {
						ForEach(CredentialIdentityEditorKind.allCases) {
							Text($0.title).tag($0)
						}
					}
					.disabled(existingIdentity != nil)
					if existingIdentity != nil {
						Text(
							"Identity type is fixed. Create a new identity to use a different authentication method."
						)
						.font(.caption)
						.foregroundStyle(.secondary)
					}
				}

				materialSection
			}
			.formStyle(.grouped)

			Divider()

			HStack {
				Button("Cancel") { dismiss() }
					.keyboardShortcut(.cancelAction)
					.disabled(isSaving)
				Spacer()
				if isSaving {
					ProgressView().controlSize(.small)
				}
				Button(existingIdentity == nil ? "Create" : "Save") {
					save()
				}
				.keyboardShortcut(.defaultAction)
				.disabled(!isValid || isSaving)
			}
			.padding()
		}
		.frame(width: 480, height: 520)
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
			Button("OK") { errorMessage = nil }
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
						? "Password" : "New password (leave blank to keep)",
					text: $password
				)
			}
		case .managedKey:
			keyMaterialSection(includeCertificate: false)
		case .sshCertificate:
			keyMaterialSection(includeCertificate: true)
		case .secureEnclaveP256:
			Section("Device-Bound Key") {
				Label(
					existingIdentity == nil
						? "A P-256 key will be created in this Mac's Secure Enclave and protected by user presence."
						: "This identity's private key remains bound to the device where it was created.",
					systemImage: "touchid"
				)
				.fixedSize(horizontal: false, vertical: true)
				Text(
					"Only the public key and identity metadata sync or appear in backups. The private key never leaves the Secure Enclave."
				)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}

	private func keyMaterialSection(
		includeCertificate: Bool
	) -> some View {
		Section(includeCertificate ? "Certificate Pair" : "Private Key") {
			LabeledContent("Private key") {
				HStack {
					Text(
						privateKeyFileName
							?? (existingIdentity == nil
								? "Not selected" : "Keep existing")
					)
					.foregroundStyle(.secondary)
					Button("Choose…") { importingPrivateKey = true }
				}
			}
			if includeCertificate {
				LabeledContent("Public certificate") {
					HStack {
						Text(
							certificateFileName
								?? (publicCertificate == nil
									? "Not selected" : "Keep existing")
						)
						.foregroundStyle(.secondary)
						Button("Choose…") { importingCertificate = true }
					}
				}
			}
			Toggle("Private key has a passphrase", isOn: $hasPassphrase)
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

	private func save() {
		isSaving = true
		Task { @MainActor in
			defer { isSaving = false }
			do {
				if kind == .secureEnclaveP256,
				   existingIdentity == nil {
					let generated = try await materialStore
						.createSecureEnclaveIdentity(
							name: name,
							username: username,
							originDeviceID:
								CredentialIdentityDeviceID.current(),
							localizedReason:
								"Create an SSH identity for \(name)"
						)
					do {
						try store.upsert(generated)
					} catch {
						try? await materialStore.delete(
							identity: generated
						)
						throw error
					}
				} else {
					try await saveStandardIdentity()
				}
				triggerSync()
				dismiss()
			} catch {
				errorMessage = String(describing: error)
			}
		}
	}

	private func saveStandardIdentity() async throws {
		let previousMaterial: CredentialIdentityMaterial?
		if let existingIdentity {
			previousMaterial = try await materialStore.snapshot(
				for: existingIdentity
			)
		} else {
			previousMaterial = nil
		}
		let materialID = existingIdentity?.source.materialID
			?? CredentialMaterialID()
		let source: CredentialIdentitySource
		let material: CredentialIdentityMaterial?
		switch kind {
		case .password:
			source = .password(materialID: materialID)
			let resolvedPassword = password.isEmpty
				? previousMaterial?.password
				: Data(password.utf8)
			material = CredentialIdentityMaterial(
				password: resolvedPassword
			)
		case .managedKey:
			source = .managedKey(
				materialID: materialID,
				hasPassphrase: hasPassphrase
			)
			material = CredentialIdentityMaterial(
				passphrase: resolvedPassphrase(previousMaterial),
				privateKey: privateKey ?? previousMaterial?.privateKey
			)
		case .sshCertificate:
			guard let certificate = publicCertificate else {
				throw CredentialIdentityValidationError
					.emptyPublicCertificate
			}
			source = .sshCertificate(
				materialID: materialID,
				publicCertificate: certificate,
				hasPassphrase: hasPassphrase
			)
			material = CredentialIdentityMaterial(
				passphrase: resolvedPassphrase(previousMaterial),
				privateKey: privateKey ?? previousMaterial?.privateKey
			)
		case .secureEnclaveP256:
			guard let existingIdentity else {
				throw SecureEnclaveIdentityError.unavailable
			}
			source = existingIdentity.source
			material = nil
		}
		var candidate = existingIdentity ?? CredentialIdentity(
			name: name,
			username: username,
			source: source
		)
		candidate.name = name
		candidate.username = username
		candidate.source = source
		if let material {
			try await materialStore.replaceMaterial(
				for: candidate,
				with: material
			)
		}
		do {
			try store.upsert(candidate)
		} catch {
			if let existingIdentity, let previousMaterial {
				try? await materialStore.replaceMaterial(
					for: existingIdentity,
					with: previousMaterial
				)
			} else if existingIdentity == nil {
				try? await materialStore.delete(identity: candidate)
			}
			throw error
		}
	}

	private func resolvedPassphrase(
		_ previous: CredentialIdentityMaterial?
	) -> Data? {
		guard hasPassphrase else { return nil }
		return passphrase.isEmpty
			? previous?.passphrase
			: Data(passphrase.utf8)
	}

	private func importPrivateKey(
		_ result: Result<[URL], any Error>
	) {
		do {
			let url = try result.get().first
			guard let url else { return }
			privateKey = try readSecurityScoped(url)
			privateKeyFileName = url.lastPathComponent
		} catch {
			errorMessage = error.localizedDescription
		}
	}

	private func importCertificate(
		_ result: Result<[URL], any Error>
	) {
		do {
			let url = try result.get().first
			guard let url else { return }
			publicCertificate = try readSecurityScoped(url)
			certificateFileName = url.lastPathComponent
		} catch {
			errorMessage = error.localizedDescription
		}
	}

	private func readSecurityScoped(_ url: URL) throws -> Data {
		let accessed = url.startAccessingSecurityScopedResource()
		defer {
			if accessed {
				url.stopAccessingSecurityScopedResource()
			}
		}
		let data = try Data(contentsOf: url)
		guard data.count <= ManagedKeyStore.maxBytes else {
			throw ManagedKeyStore.Error.tooLarge
		}
		return data
	}
}

private enum CredentialIdentityDeviceID {
	private static let defaultsKey = "catermCredentialIdentityDeviceID"

	static func current(defaults: UserDefaults = .standard) -> UUID {
		if let value = defaults.string(forKey: defaultsKey),
		   let id = UUID(uuidString: value) {
			return id
		}
		let id = UUID()
		defaults.set(id.uuidString, forKey: defaultsKey)
		return id
	}
}

private extension CredentialIdentityMaterial {
	var hasAnyMaterial: Bool {
		password != nil
			|| passphrase != nil
			|| privateKey != nil
			|| secureEnclaveKeyBlob != nil
	}
}
