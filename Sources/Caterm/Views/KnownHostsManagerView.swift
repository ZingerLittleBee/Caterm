import KnownHostsStore
import SwiftUI
import UniformTypeIdentifiers

enum KnownHostsWindow {
	static let id = "known-hosts"
}

struct KnownHostsManagerView: View {
	private let repository: KnownHostsRepository
	@State private var snapshot = KnownHostsSnapshot(records: [], issues: [])
	@State private var selection: Set<KnownHostRecord.ID> = []
	@State private var query = ""
	@State private var sortOrder = [
		KeyPathComparator(\KnownHostRecord.hostDisplay)
	]
	@State private var presentingImporter = false
	@State private var pendingForget: KnownHostRecord?
	@State private var errorMessage: String?
	@State private var statusMessage: String?
	@State private var isWorking = false

	init(catermURL: URL, userURL: URL) {
		repository = KnownHostsRepository(
			catermURL: catermURL,
			userURL: userURL
		)
	}

	var body: some View {
		let records = visibleRecords.sorted(using: sortOrder)
		VStack(spacing: 0) {
			Table(records, selection: $selection, sortOrder: $sortOrder) {
				TableColumn("Host", value: \.hostDisplay) { record in
					Label {
						Text(record.hostDisplay)
					} icon: {
						Image(systemName: iconName(for: record))
							.foregroundStyle(iconColor(for: record))
					}
					.help(record.isHashed ? "The hostname is hashed in the source file." : record.hostDisplay)
				}
				.width(min: 140, ideal: 190)
				TableColumn("Fingerprint") { record in
					Text(record.fingerprint ?? "Unavailable")
						.font(.system(.body, design: .monospaced))
						.foregroundStyle(record.fingerprint == nil ? .secondary : .primary)
						.help(record.fingerprint ?? record.rawLine)
				}
				.width(min: 220, ideal: 280)
				TableColumn("Key Type", value: \.keyTypeDisplay)
				.width(min: 105, ideal: 130)
				TableColumn("Trust", value: \.markerDisplay)
					.width(min: 110, ideal: 130)
				TableColumn("Source", value: \.sourceDisplay)
				.width(min: 75, ideal: 85)
			}
			.contextMenu(forSelectionType: KnownHostRecord.ID.self) { selectedIDs in
				if let record = record(for: selectedIDs) {
					Button("Forget Known Host…", role: .destructive) {
						pendingForget = record
					}
				}
			}
			.overlay {
				if records.isEmpty {
					if query.isEmpty && snapshot.records.isEmpty {
						ContentUnavailableView(
							"No Known Hosts",
							systemImage: "checkmark.shield",
							description: Text(
								"Connect to an SSH host or import an OpenSSH known_hosts file."
							)
						)
					} else {
						ContentUnavailableView.search(text: query)
					}
				}
			}
			if let selectedRecord {
				Divider()
				VStack(alignment: .leading, spacing: 5) {
					detailRow(
						label: "Host",
						value: selectedRecord.hosts.isEmpty
							? selectedRecord.rawLine
							: selectedRecord.hosts.joined(separator: ", ")
					)
					detailRow(
						label: "Fingerprint",
						value: selectedRecord.fingerprint ?? "Unavailable"
					)
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 9)
			}

			Divider()
			HStack(spacing: 8) {
				if isWorking {
					ProgressView()
						.controlSize(.small)
				} else if !snapshot.issues.isEmpty {
					Image(systemName: "exclamationmark.triangle")
						.foregroundStyle(.orange)
				} else {
					Image(systemName: "info.circle")
				}
				Text(footerText)
					.lineLimit(1)
				Spacer()
				Text("\(snapshot.records.count) \(snapshot.records.count == 1 ? "entry" : "entries")")
			}
			.font(.caption)
			.foregroundStyle(.secondary)
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
		}
		.searchable(text: $query, prompt: "Search hosts, fingerprints, or key types")
		.toolbar {
			ToolbarItemGroup(placement: .primaryAction) {
				Button {
					Task { await refresh() }
				} label: {
					Label("Refresh", systemImage: "arrow.clockwise")
				}
				.disabled(isWorking)
				Button {
					presentingImporter = true
				} label: {
					Label("Import", systemImage: "square.and.arrow.down")
				}
				.disabled(isWorking)
				Button(role: .destructive) {
					pendingForget = selectedRecord
				} label: {
					Label("Forget", systemImage: "trash")
				}
				.disabled(selectedRecord == nil || isWorking)
			}
		}
		.fileImporter(
			isPresented: $presentingImporter,
			allowedContentTypes: [.data],
			allowsMultipleSelection: false,
			onCompletion: importFile
		)
		.confirmationDialog(
			"Forget this known host?",
			isPresented: Binding(
				get: { pendingForget != nil },
				set: { if !$0 { pendingForget = nil } }
			),
			titleVisibility: .visible,
			presenting: pendingForget
		) { record in
			Button("Forget from \(record.source.displayName)", role: .destructive) {
				forget(record)
			}
			Button("Cancel", role: .cancel) {}
		} message: { record in
			Text(
				"OpenSSH will stop trusting \(record.hostDisplay) through this source file. Other matching entries remain unchanged."
			)
		}
		.alert(
			"Known Hosts Error",
			isPresented: Binding(
				get: { errorMessage != nil },
				set: { if !$0 { errorMessage = nil } }
			),
			presenting: errorMessage
		) { _ in
			Button("OK") { errorMessage = nil }
		} message: { Text($0) }
		.task { await refresh() }
		.frame(minWidth: 800, minHeight: 420)
	}

	private var visibleRecords: [KnownHostRecord] {
		let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !normalizedQuery.isEmpty else { return snapshot.records }
		return snapshot.records.filter {
			$0.searchText.localizedCaseInsensitiveContains(normalizedQuery)
		}
	}

	private var selectedRecord: KnownHostRecord? {
		guard let id = selection.first else { return nil }
		return visibleRecords.first(where: { $0.id == id })
	}

	private var footerText: String {
		if let statusMessage { return statusMessage }
		if let issue = snapshot.issues.first {
			return "Could not read \(issue.source.displayName): \(issue.message)"
		}
		return "Entries are read from both Caterm and your OpenSSH known_hosts file."
	}

	private func record(
		for selectedIDs: Set<KnownHostRecord.ID>
	) -> KnownHostRecord? {
		guard let id = selectedIDs.first else { return nil }
		return snapshot.records.first(where: { $0.id == id })
	}

	private func iconName(for record: KnownHostRecord) -> String {
		if !record.isValid { return "exclamationmark.triangle.fill" }
		switch record.marker {
		case "@revoked": return "exclamationmark.shield.fill"
		case "@cert-authority": return "checkmark.seal.fill"
		default: return "key.horizontal"
		}
	}

	private func iconColor(for record: KnownHostRecord) -> Color {
		if !record.isValid { return .orange }
		return record.marker == "@revoked" ? .red : .secondary
	}

	private func detailRow(label: String, value: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text(label)
				.foregroundStyle(.secondary)
				.frame(width: 72, alignment: .trailing)
			Text(value)
				.font(.system(.caption, design: .monospaced))
				.textSelection(.enabled)
				.lineLimit(1)
				.truncationMode(.middle)
				.help(value)
		}
		.font(.caption)
	}

	@MainActor
	private func refresh() async {
		isWorking = true
		let repository = repository
		let loaded = await Task.detached { repository.load() }.value
		snapshot = loaded
		selection.formIntersection(Set(loaded.records.map(\.id)))
		isWorking = false
	}

	private func forget(_ record: KnownHostRecord) {
		pendingForget = nil
		let repository = repository
		Task { @MainActor in
			isWorking = true
			do {
				try await Task.detached { try repository.delete(record) }.value
				statusMessage = "Forgot \(record.hostDisplay) from \(record.source.displayName)."
				await refresh()
			} catch {
				isWorking = false
				errorMessage = error.localizedDescription
			}
		}
	}

	private func importFile(_ result: Result<[URL], Error>) {
		guard case .success(let urls) = result, let url = urls.first else {
			if case .failure(let error) = result {
				errorMessage = error.localizedDescription
			}
			return
		}
		let repository = repository
		Task { @MainActor in
			isWorking = true
			let accessed = url.startAccessingSecurityScopedResource()
			defer {
				if accessed { url.stopAccessingSecurityScopedResource() }
			}
			do {
				let count = try await Task.detached {
					try repository.importEntries(from: url)
				}.value
				statusMessage = count == 1
					? "Imported 1 known-host entry into Caterm."
					: "Imported \(count) known-host entries into Caterm."
				await refresh()
			} catch {
				isWorking = false
				errorMessage = error.localizedDescription
			}
		}
	}
}
