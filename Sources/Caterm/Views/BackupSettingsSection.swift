import AppKit
import BackupArchive
import BackupService
import ManagedKeyStore
import SessionStore
import SettingsStore
import SnippetStore
import SwiftUI
import UniformTypeIdentifiers

/// "Backup" section of the Sync preferences tab: encrypted export/import
/// of the full user configuration (`.catermbackup`, ADR 0002) — manual
/// sync for users who keep iCloud sync off.
struct BackupSettingsSection: View {
	let sessionStore: SessionStore
	let managedKeys: ManagedKeyStore
	let snippetStore: SnippetStore?
	let bookmarkStore: RemoteBookmarkStore?
	@EnvironmentObject private var settingsStore: SettingsStore

	@State private var showingExportSheet = false
	@State private var pendingImport: PendingImport?
	@State private var importPrompt: ImportPrompt?
	@State private var importSummary: BackupImportSummary?
	@State private var importError: String?
	@State private var isWorking = false

	/// File picked + passphrase being collected.
	private struct ImportPrompt: Identifiable {
		let url: URL
		var id: String { url.path }
	}

	/// Decrypted archive + computed plan awaiting user confirmation.
	private struct PendingImport: Identifiable {
		let id = UUID()
		let payload: BackupPayload
		let plan: BackupMergePlan
	}

	var body: some View {
		Section("Backup") {
			HStack {
				Button("Export…") { showingExportSheet = true }
					.disabled(isWorking)
				Button("Import…") { pickImportFile() }
					.disabled(isWorking)
				if isWorking { ProgressView().controlSize(.small) }
			}
			Text("Move your hosts, keys, snippets, and settings between Macs (and iPhones) as a single passphrase-encrypted file — no iCloud required.")
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.sheet(isPresented: $showingExportSheet) {
			ExportBackupSheet { passphrase, includeSecrets in
				try await runExport(passphrase: passphrase, includeSecrets: includeSecrets)
			}
		}
		.sheet(item: $importPrompt) { prompt in
			ImportPassphraseSheet(fileName: prompt.url.lastPathComponent) { passphrase in
				try await decryptAndPlan(url: prompt.url, passphrase: passphrase)
			} onDone: {
				importPrompt = nil
			}
		}
		.sheet(item: $pendingImport) { pending in
			ImportPreviewSheet(
				plan: pending.plan,
				onConfirm: { Task { await runApply(pending) } },
				onCancel: { pendingImport = nil }
			)
		}
		.alert("Import Complete", isPresented: Binding(
			get: { importSummary != nil },
			set: { if !$0 { importSummary = nil } }
		)) {
			Button("OK") { importSummary = nil }
		} message: {
			if let importSummary {
				Text(summaryText(importSummary))
			}
		}
		.alert("Import Failed", isPresented: Binding(
			get: { importError != nil },
			set: { if !$0 { importError = nil } }
		)) {
			Button("OK") { importError = nil }
		} message: {
			if let importError { Text(importError) }
		}
	}

	// MARK: Export

	private func runExport(passphrase: String, includeSecrets: Bool) async throws {
		let panel = NSSavePanel()
		if let type = UTType(filenameExtension: BackupArchive.fileExtension) {
			panel.allowedContentTypes = [type]
		}
		let day = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
		panel.nameFieldStringValue = "Caterm-Backup-\(day).\(BackupArchive.fileExtension)"
		guard panel.runModal() == .OK, let url = panel.url else { return }

		isWorking = true
		defer { isWorking = false }
		let payload = try BackupExporter.makePayload(
			includeSecrets: includeSecrets,
			appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
			sessionStore: sessionStore,
			managedKeys: managedKeys,
			snippets: snippetStore?.snippets ?? [],
			settings: settingsStore.settings,
			bookmarks: { hostId in bookmarkStore?.bookmarks(for: hostId) ?? [] }
		)
		let plaintext = try payload.encoded()
		// scrypt (N=2^17) takes a few hundred ms — keep it off the main actor.
		let sealed = try await Task.detached(priority: .userInitiated) {
			try BackupArchive.seal(payload: plaintext, passphrase: passphrase)
		}.value
		try sealed.write(to: url, options: .atomic)
	}

	// MARK: Import

	private func pickImportFile() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		if let type = UTType(filenameExtension: BackupArchive.fileExtension) {
			panel.allowedContentTypes = [type]
		}
		guard panel.runModal() == .OK, let url = panel.url else { return }
		importPrompt = ImportPrompt(url: url)
	}

	/// Decrypt (off-main), compute the merge plan, and stage the preview.
	/// Throws user-readable errors back into the passphrase sheet.
	private func decryptAndPlan(url: URL, passphrase: String) async throws {
		let sealed = try Data(contentsOf: url)
		let plaintext = try await Task.detached(priority: .userInitiated) {
			try BackupArchive.open(sealed, passphrase: passphrase)
		}.value
		let payload = try BackupPayload.decode(plaintext)
		let plan = BackupMergePlanner.plan(
			payload: payload,
			localHosts: sessionStore.hosts,
			needsCredentialSetup: { sessionStore.needsCredentialSetup($0) },
			localSnippets: snippetStore?.snippets ?? [],
			localSettingsRevision: settingsStore.settings.revision,
			localBookmarks: { bookmarkStore?.bookmarks(for: $0) ?? [] },
			localKnownHostsLines: knownHostsLines()
		)
		importPrompt = nil
		pendingImport = PendingImport(payload: payload, plan: plan)
	}

	private func runApply(_ pending: PendingImport) async {
		pendingImport = nil
		isWorking = true
		defer { isWorking = false }
		do {
			importSummary = try await BackupImporter.apply(
				plan: pending.plan,
				sessionStore: sessionStore,
				managedKeys: managedKeys,
				snippetStore: snippetStore,
				settingsStore: settingsStore,
				archiveSettings: pending.payload.settings,
				bookmarkStore: bookmarkStore
			)
		} catch {
			importError = error.localizedDescription
		}
	}

	private func knownHostsLines() -> [String] {
		guard let text = try? String(contentsOfFile: sessionStore.knownHostsCaterm,
		                             encoding: .utf8) else { return [] }
		return text.split(separator: "\n").map(String.init)
	}

	private func summaryText(_ s: BackupImportSummary) -> String {
		var lines: [String] = []
		lines.append("Hosts: \(s.hostsAdded) added, \(s.hostsUpdated) updated, "
			+ "\(s.hostsCredentialsOnly) credentials filled, \(s.hostsSkipped) kept (local newer)")
		lines.append("Snippets: \(s.snippetsAdded) added, \(s.snippetsUpdated) updated, "
			+ "\(s.snippetsSkipped) kept")
		lines.append(s.settingsApplied ? "Settings: applied" : "Settings: kept (local newer or absent)")
		lines.append("Bookmarks: \(s.bookmarksAdded) added")
		lines.append("Known hosts: \(s.knownHostsAppended) fingerprints added")
		return lines.joined(separator: "\n")
	}
}

// MARK: - Export sheet

/// Passphrase entry for export: two fields with a show/hide toggle, a
/// random-passphrase generator, and the include-secrets choice.
private struct ExportBackupSheet: View {
	/// Runs the export; the sheet stays up and shows the error on throw.
	let onExport: (_ passphrase: String, _ includeSecrets: Bool) async throws -> Void
	@Environment(\.dismiss) private var dismiss

	@State private var passphrase = ""
	@State private var confirmation = ""
	@State private var revealed = false
	@State private var includeSecrets = true
	@State private var errorMessage: String?
	@State private var isExporting = false

	private var passphraseTooShort: Bool {
		!passphrase.isEmpty && passphrase.count < BackupArchive.minimumPassphraseLength
	}
	private var mismatch: Bool {
		!confirmation.isEmpty && passphrase != confirmation
	}
	private var isValid: Bool {
		passphrase.count >= BackupArchive.minimumPassphraseLength
			&& passphrase == confirmation
	}

	var body: some View {
		VStack(spacing: 0) {
			VStack(alignment: .leading, spacing: 14) {
				Text("Export Encrypted Backup").font(.headline)
				Text("The file contains your hosts, keys, snippets, and settings, encrypted with this passphrase. The passphrase is not stored anywhere — without it the backup cannot be opened.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)

				VStack(alignment: .leading, spacing: 5) {
					FieldLabel("Passphrase (min. \(BackupArchive.minimumPassphraseLength) characters)")
					HStack {
						Group {
							if revealed {
								TextField("", text: $passphrase)
							} else {
								SecureField("", text: $passphrase)
							}
						}
						.textFieldStyle(.roundedBorder)
						Button {
							revealed.toggle()
						} label: {
							Image(systemName: revealed ? "eye.slash" : "eye")
						}
						.buttonStyle(.borderless)
						.help(revealed ? "Hide passphrase" : "Show passphrase")
						Button("Generate") {
							let generated = BackupArchive.randomPassphrase()
							passphrase = generated
							confirmation = generated
							revealed = true
						}
						.help("Generate a strong random passphrase. Write it down — it is shown only here.")
					}
					if passphraseTooShort {
						Text("At least \(BackupArchive.minimumPassphraseLength) characters.")
							.font(.caption).foregroundStyle(.red)
					}
				}

				VStack(alignment: .leading, spacing: 5) {
					FieldLabel("Confirm passphrase")
					Group {
						if revealed {
							TextField("", text: $confirmation)
						} else {
							SecureField("", text: $confirmation)
						}
					}
					.textFieldStyle(.roundedBorder)
					if mismatch {
						Text("Passphrases don't match.")
							.font(.caption).foregroundStyle(.red)
					}
				}

				Toggle("Include passwords and private keys", isOn: $includeSecrets)
					.help("Off exports host metadata only — you'll re-enter credentials after importing.")

				if let errorMessage {
					Text(errorMessage).font(.caption).foregroundStyle(.red)
				}
			}
			.padding(20)

			Divider()

			HStack {
				Button("Cancel") { dismiss() }
					.keyboardShortcut(.cancelAction)
					.disabled(isExporting)
				Spacer()
				Button("Export…") { export() }
					.keyboardShortcut(.defaultAction)
					.disabled(!isValid || isExporting)
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 14)
		}
		.frame(width: 440)
	}

	private func export() {
		errorMessage = nil
		isExporting = true
		Task {
			do {
				try await onExport(passphrase, includeSecrets)
				dismiss()
			} catch {
				errorMessage = error.localizedDescription
				isExporting = false
			}
		}
	}
}

// MARK: - Import passphrase sheet

private struct ImportPassphraseSheet: View {
	let fileName: String
	/// Decrypts and stages the preview; throws back into this sheet.
	let onSubmit: (_ passphrase: String) async throws -> Void
	let onDone: () -> Void

	@State private var passphrase = ""
	@State private var errorMessage: String?
	@State private var isDecrypting = false

	var body: some View {
		VStack(spacing: 0) {
			VStack(alignment: .leading, spacing: 14) {
				Text("Import Backup").font(.headline)
				Text(fileName)
					.font(.caption)
					.foregroundStyle(.secondary)
				VStack(alignment: .leading, spacing: 5) {
					FieldLabel("Passphrase")
					SecureField("", text: $passphrase)
						.textFieldStyle(.roundedBorder)
						.onSubmit { submit() }
				}
				if let errorMessage {
					Text(errorMessage).font(.caption).foregroundStyle(.red)
				}
			}
			.padding(20)

			Divider()

			HStack {
				Button("Cancel") { onDone() }
					.keyboardShortcut(.cancelAction)
					.disabled(isDecrypting)
				Spacer()
				if isDecrypting { ProgressView().controlSize(.small) }
				Button("Unlock") { submit() }
					.keyboardShortcut(.defaultAction)
					.disabled(passphrase.isEmpty || isDecrypting)
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 14)
		}
		.frame(width: 400)
	}

	private func submit() {
		guard !passphrase.isEmpty, !isDecrypting else { return }
		errorMessage = nil
		isDecrypting = true
		Task {
			do {
				try await onSubmit(passphrase)
				// Parent swaps this sheet for the preview on success.
			} catch BackupArchiveError.wrongPassphrase {
				errorMessage = "Wrong passphrase."
				isDecrypting = false
			} catch let BackupArchiveError.corruptArchive(reason) {
				errorMessage = "This file can't be imported (\(reason))."
				isDecrypting = false
			} catch let BackupArchiveError.unsupportedFormatVersion(v) {
				errorMessage = "This backup was created by a newer Caterm (format v\(v)). Update Caterm to import it."
				isDecrypting = false
			} catch {
				errorMessage = error.localizedDescription
				isDecrypting = false
			}
		}
	}
}

// MARK: - Import preview sheet

/// Detailed merge plan shown before anything is written. The user
/// confirms exactly what will be added/updated/kept.
private struct ImportPreviewSheet: View {
	let plan: BackupMergePlan
	let onConfirm: () -> Void
	let onCancel: () -> Void

	var body: some View {
		VStack(spacing: 0) {
			VStack(alignment: .leading, spacing: 4) {
				Text("Review Import").font(.headline)
				Text("Nothing is written until you confirm. Existing data is never deleted; when both sides changed, the newer one wins.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(20)

			Divider()

			if plan.isEmpty {
				Text("Everything in this backup is already present (or older than your local data). There is nothing to import.")
					.foregroundStyle(.secondary)
					.padding(24)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				List {
					if !plan.hosts.isEmpty {
						Section("Hosts") {
							ForEach(plan.hosts) { action in
								hostRow(action)
							}
						}
					}
					if !plan.snippets.isEmpty {
						Section("Snippets") {
							ForEach(plan.snippets) { action in
								row(icon: "text.alignleft",
								    title: action.archiveSnippet.name,
								    subtitle: nil,
								    badge: snippetBadge(action.kind))
							}
						}
					}
					if plan.settings != .none {
						Section("Settings") {
							row(icon: "gearshape",
							    title: "Application settings",
							    subtitle: nil,
							    badge: plan.settings == .apply
							    	? ("Apply (backup is newer)", .blue)
							    	: ("Keep local (newer)", .secondary))
						}
					}
					let addedBookmarks = plan.bookmarks.filter { $0.kind == .add }
					if !addedBookmarks.isEmpty {
						Section("Path Bookmarks") {
							ForEach(addedBookmarks) { action in
								row(icon: "bookmark",
								    title: action.archiveBookmark.label,
								    subtitle: action.archiveBookmark.path,
								    badge: ("Add", .green))
							}
						}
					}
					if !plan.knownHostsToAppend.isEmpty {
						Section("Server Fingerprints") {
							row(icon: "checkmark.shield",
							    title: "\(plan.knownHostsToAppend.count) known-host entries",
							    subtitle: "Skips first-connection fingerprint prompts for servers you already trusted.",
							    badge: ("Add", .green))
						}
					}
				}
			}

			Divider()

			HStack {
				Button("Cancel") { onCancel() }
					.keyboardShortcut(.cancelAction)
				Spacer()
				Button("Import") { onConfirm() }
					.keyboardShortcut(.defaultAction)
					.disabled(plan.isEmpty)
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 14)
		}
		.frame(width: 520, height: 460)
	}

	private func hostRow(_ action: BackupMergePlan.HostAction) -> some View {
		let h = action.archiveHost
		let badge: (String, Color)
		switch action.kind {
		case .add:
			badge = (action.appliesSecrets ? "Add (with credentials)" : "Add", .green)
		case .update:
			badge = (action.appliesSecrets ? "Update (with credentials)" : "Update", .blue)
		case .credentialsOnly:
			badge = ("Fill missing credentials", .orange)
		case .skipLocalNewer:
			badge = ("Keep local (newer)", .secondary)
		}
		return row(icon: "server.rack",
		           title: h.name,
		           subtitle: "\(h.username)@\(h.hostname):\(h.port)",
		           badge: badge)
	}

	private func row(icon: String, title: String, subtitle: String?,
	                 badge: (String, Color)) -> some View {
		HStack {
			Image(systemName: icon).foregroundStyle(.secondary)
			VStack(alignment: .leading, spacing: 1) {
				Text(title)
				if let subtitle {
					Text(subtitle).font(.caption).foregroundStyle(.secondary)
				}
			}
			Spacer()
			Text(badge.0)
				.font(.caption.weight(.medium))
				.foregroundStyle(badge.1)
		}
	}

	private func snippetBadge(_ kind: BackupMergePlan.SnippetAction.Kind) -> (String, Color) {
		switch kind {
		case .add: return ("Add", .green)
		case .update: return ("Update (backup is newer)", .blue)
		case .skipLocalNewer: return ("Keep local (newer)", .secondary)
		}
	}
}
