#if canImport(UIKit)
import BackupArchive
import BackupService
import KeychainStore
import ManagedKeyStore
import SnippetSyncClient
import SSHCommandBuilder
import SwiftUI
import UniformTypeIdentifiers

/// "Backup" section of mobile Settings: encrypted export/import of the
/// `.catermbackup` format shared with the Mac app. iOS applies the subset
/// it has stores for (hosts + credentials + snippets); macOS settings,
/// path bookmarks, and known-host fingerprints in the archive are shown
/// as skipped.
struct MobileBackupSection: View {
	@Binding var hosts: [SSHHost]
	@Binding var snippets: [Snippet]

	@State private var showingExportSheet = false
	@State private var showingImportPicker = false
	@State private var importPromptURL: URL?
	@State private var pendingImport: PendingImport?
	@State private var importSummary: BackupImportSummary?
	@State private var errorMessage: String?

	private struct PendingImport: Identifiable {
		let id = UUID()
		let payload: BackupPayload
		let plan: BackupMergePlan
	}

	private var keychain: KeychainStore {
		KeychainStore(service: MobileCredentialWriter.defaultService, accessGroup: nil)
	}

	var body: some View {
		Section {
			Button {
				showingExportSheet = true
			} label: {
				Label("Export Encrypted Backup", systemImage: "square.and.arrow.up")
			}
			Button {
				showingImportPicker = true
			} label: {
				Label("Import Backup", systemImage: "square.and.arrow.down")
			}
		} header: {
			Text("Backup")
		} footer: {
			Text("Moves hosts, keys, and snippets between devices as one passphrase-encrypted file — the same format as the Mac app. No iCloud required.")
		}
		.sheet(isPresented: $showingExportSheet) {
			MobileExportSheet { passphrase, includeSecrets in
				try await exportFile(passphrase: passphrase, includeSecrets: includeSecrets)
			}
		}
		.fileImporter(
			isPresented: $showingImportPicker,
			allowedContentTypes: importTypes
		) { result in
			if case let .success(url) = result { importPromptURL = url }
		}
		.sheet(isPresented: Binding(
			get: { importPromptURL != nil },
			set: { if !$0 { importPromptURL = nil } }
		)) {
			if let url = importPromptURL {
				MobileImportPassphraseSheet(fileName: url.lastPathComponent) { passphrase in
					try decryptAndPlan(url: url, passphrase: passphrase)
				} onCancel: {
					importPromptURL = nil
				}
			}
		}
		.sheet(item: $pendingImport) { pending in
			MobileImportPreviewSheet(
				plan: pending.plan,
				archiveHasDesktopOnlyData: pending.payload.settings != nil
					|| !pending.payload.bookmarks.isEmpty
					|| !pending.payload.knownHosts.isEmpty,
				onConfirm: { Task { await apply(pending) } },
				onCancel: { pendingImport = nil }
			)
		}
		.alert("Import Complete", isPresented: Binding(
			get: { importSummary != nil },
			set: { if !$0 { importSummary = nil } }
		)) {
			Button("OK") { importSummary = nil }
		} message: {
			if let s = importSummary {
				Text("Hosts: \(s.hostsAdded) added, \(s.hostsUpdated) updated, \(s.hostsCredentialsOnly) credentials filled, \(s.hostsSkipped) kept.\nSnippets: \(s.snippetsAdded) added, \(s.snippetsUpdated) updated, \(s.snippetsSkipped) kept.")
			}
		}
		.alert("Backup Error", isPresented: Binding(
			get: { errorMessage != nil },
			set: { if !$0 { errorMessage = nil } }
		)) {
			Button("OK") { errorMessage = nil }
		} message: {
			if let errorMessage { Text(errorMessage) }
		}
	}

	private var importTypes: [UTType] {
		if let t = UTType(filenameExtension: BackupArchive.fileExtension) {
			return [t, .json, .data]
		}
		return [.data]
	}

	/// Build + seal the archive into a temp file; the export sheet offers
	/// it via ShareLink.
	private func exportFile(passphrase: String, includeSecrets: Bool) async throws -> URL {
		let payload = MobileBackupService.makePayload(
			hosts: hosts, snippets: snippets,
			includeSecrets: includeSecrets, keychain: keychain
		)
		let plaintext = try payload.encoded()
		let sealed = try await Task.detached(priority: .userInitiated) {
			try BackupArchive.seal(payload: plaintext, passphrase: passphrase)
		}.value
		let day = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("Caterm-Backup-\(day).\(BackupArchive.fileExtension)")
		try sealed.write(to: url, options: .atomic)
		return url
	}

	private func decryptAndPlan(url: URL, passphrase: String) throws {
		// Files-app URLs are security-scoped.
		let scoped = url.startAccessingSecurityScopedResource()
		defer { if scoped { url.stopAccessingSecurityScopedResource() } }
		let sealed = try Data(contentsOf: url)
		let plaintext = try BackupArchive.open(sealed, passphrase: passphrase)
		let payload = try BackupPayload.decode(plaintext)
		let plan = MobileBackupService.plan(
			payload: payload, hosts: hosts, snippets: snippets, keychain: keychain)
		importPromptURL = nil
		pendingImport = PendingImport(payload: payload, plan: plan)
	}

	private func apply(_ pending: PendingImport) async {
		pendingImport = nil
		do {
			let result = try await MobileBackupService.apply(
				plan: pending.plan, hosts: hosts, snippets: snippets,
				keychain: keychain, managedKeys: ManagedKeyStore()
			)
			hosts = result.hosts
			snippets = result.snippets
			importSummary = result.summary
		} catch {
			errorMessage = error.localizedDescription
		}
	}
}

// MARK: - Export sheet

private struct MobileExportSheet: View {
	let makeFile: (_ passphrase: String, _ includeSecrets: Bool) async throws -> URL
	@Environment(\.dismiss) private var dismiss

	@State private var passphrase = ""
	@State private var confirmation = ""
	@State private var revealed = false
	@State private var includeSecrets = true
	@State private var exportedFile: URL?
	@State private var isWorking = false
	@State private var errorMessage: String?

	private var isValid: Bool {
		passphrase.count >= BackupArchive.minimumPassphraseLength
			&& passphrase == confirmation
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					passphraseField("Passphrase", text: $passphrase)
					passphraseField("Confirm passphrase", text: $confirmation)
					Toggle("Show passphrase", isOn: $revealed)
					Button("Generate Strong Passphrase") {
						let generated = BackupArchive.randomPassphrase()
						passphrase = generated
						confirmation = generated
						revealed = true
					}
				} footer: {
					Text("At least \(BackupArchive.minimumPassphraseLength) characters. The passphrase is not stored anywhere — without it the backup cannot be opened.")
				}

				Section {
					Toggle("Include passwords and private keys", isOn: $includeSecrets)
				}

				if let errorMessage {
					Section { Text(errorMessage).foregroundStyle(.red) }
				}

				Section {
					if let exportedFile {
						ShareLink(item: exportedFile) {
							Label("Save or Share Backup File", systemImage: "square.and.arrow.up")
						}
					} else {
						Button {
							create()
						} label: {
							if isWorking {
								HStack { ProgressView(); Text("Encrypting…") }
							} else {
								Text("Create Backup")
							}
						}
						.disabled(!isValid || isWorking)
					}
				}
			}
			.navigationTitle("Export Backup")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Done") { dismiss() }
				}
			}
		}
	}

	@ViewBuilder
	private func passphraseField(_ label: String, text: Binding<String>) -> some View {
		if revealed {
			TextField(label, text: text)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
		} else {
			SecureField(label, text: text)
		}
	}

	private func create() {
		errorMessage = nil
		isWorking = true
		Task {
			do {
				exportedFile = try await makeFile(passphrase, includeSecrets)
			} catch {
				errorMessage = error.localizedDescription
			}
			isWorking = false
		}
	}
}

// MARK: - Import passphrase sheet

private struct MobileImportPassphraseSheet: View {
	let fileName: String
	let onSubmit: (_ passphrase: String) throws -> Void
	let onCancel: () -> Void

	@State private var passphrase = ""
	@State private var errorMessage: String?
	@State private var isWorking = false

	var body: some View {
		NavigationStack {
			Form {
				Section {
					SecureField("Passphrase", text: $passphrase)
						.onSubmit { submit() }
				} header: {
					Text(fileName)
				}
				if let errorMessage {
					Section { Text(errorMessage).foregroundStyle(.red) }
				}
				Section {
					Button {
						submit()
					} label: {
						if isWorking {
							HStack { ProgressView(); Text("Decrypting…") }
						} else {
							Text("Unlock")
						}
					}
					.disabled(passphrase.isEmpty || isWorking)
				}
			}
			.navigationTitle("Import Backup")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { onCancel() }
				}
			}
		}
	}

	private func submit() {
		guard !passphrase.isEmpty, !isWorking else { return }
		errorMessage = nil
		isWorking = true
		// Decryption is scrypt-bound (~hundreds of ms) — hop off the main
		// actor, then deliver the result back.
		let entered = passphrase
		Task.detached(priority: .userInitiated) {
			do {
				try await MainActor.run { try onSubmit(entered) }
			} catch BackupArchiveError.wrongPassphrase {
				await MainActor.run {
					errorMessage = "Wrong passphrase."
					isWorking = false
				}
			} catch {
				await MainActor.run {
					errorMessage = "This file can't be imported."
					isWorking = false
				}
			}
		}
	}
}

// MARK: - Import preview sheet

private struct MobileImportPreviewSheet: View {
	let plan: BackupMergePlan
	let archiveHasDesktopOnlyData: Bool
	let onConfirm: () -> Void
	let onCancel: () -> Void

	var body: some View {
		NavigationStack {
			List {
				if !plan.hosts.isEmpty {
					Section("Hosts") {
						ForEach(plan.hosts) { action in
							let h = action.archiveHost
							VStack(alignment: .leading, spacing: 2) {
								Text(h.name)
								Text("\(h.username)@\(h.hostname):\(h.port)")
									.font(.caption).foregroundStyle(.secondary)
								Text(hostBadge(action))
									.font(.caption.weight(.medium))
									.foregroundStyle(hostBadgeColor(action.kind))
							}
						}
					}
				}
				if !plan.snippets.isEmpty {
					Section("Snippets") {
						ForEach(plan.snippets) { action in
							HStack {
								Text(action.archiveSnippet.name)
								Spacer()
								Text(snippetBadge(action.kind))
									.font(.caption.weight(.medium))
									.foregroundStyle(.secondary)
							}
						}
					}
				}
				if archiveHasDesktopOnlyData {
					Section {
						Label("Mac-only data in this backup (settings, path bookmarks, server fingerprints) doesn't apply on iOS and will be skipped.",
						      systemImage: "info.circle")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				Section {
					Text("Nothing is written until you confirm. Existing data is never deleted; when both sides changed, the newer one wins.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			.navigationTitle("Review Import")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { onCancel() }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Import") { onConfirm() }
						.disabled(plan.isEmpty)
				}
			}
		}
	}

	private func hostBadge(_ action: BackupMergePlan.HostAction) -> String {
		switch action.kind {
		case .add:
			return action.appliesSecrets ? "Add (with credentials)" : "Add"
		case .update:
			return action.appliesSecrets ? "Update (with credentials)" : "Update"
		case .credentialsOnly:
			return "Fill missing credentials"
		case .skipLocalNewer:
			return "Keep local (newer)"
		}
	}

	private func hostBadgeColor(_ kind: BackupMergePlan.HostAction.Kind) -> Color {
		switch kind {
		case .add: return .green
		case .update: return .blue
		case .credentialsOnly: return .orange
		case .skipLocalNewer: return .secondary
		}
	}

	private func snippetBadge(_ kind: BackupMergePlan.SnippetAction.Kind) -> String {
		switch kind {
		case .add: return "Add"
		case .update: return "Update"
		case .skipLocalNewer: return "Keep local"
		}
	}
}
#endif
