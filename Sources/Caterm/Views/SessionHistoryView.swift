import HostSyncStore
import SessionHistory
import SessionStore
import SSHCommandBuilder
import SwiftUI

enum SessionHistoryWindow {
	static let id = "session-history"
}

struct SessionHistoryView: View {
	@EnvironmentObject private var historyStore: SessionHistoryStore
	@EnvironmentObject private var sessionStore: SessionStore
	@EnvironmentObject private var preferences: SyncPreferences
	@Environment(\.openWindow) private var openWindow
	@State private var selection: Set<UUID> = []
	@State private var query = ""
	@State private var sortOrder = [
		KeyPathComparator(\SessionHistoryRow.startedAt, order: .reverse)
	]
	@State private var showingClearConfirmation = false
	@State private var errorMessage: String?

	var body: some View {
		TimelineView(.periodic(from: .now, by: 1)) { context in
			let rows = visibleRows(now: context.date)
			VStack(spacing: 0) {
				Table(rows, selection: $selection, sortOrder: $sortOrder) {
					TableColumn("Host", value: \.hostName)
						.width(min: 120, ideal: 150)
					TableColumn("Address", value: \.address)
						.width(min: 170, ideal: 200)
					TableColumn("Started", value: \.startedAt) { row in
						Text(row.startedAt, format: .dateTime
							.month(.abbreviated)
							.day()
							.hour()
							.minute()
							.second())
					}
					.width(min: 145, ideal: 165)
					TableColumn("Duration", value: \.durationSeconds) { row in
						Text(row.durationText)
							.monospacedDigit()
					}
					.width(min: 70, ideal: 80)
					TableColumn("Result", value: \.resultText) { row in
						Label(row.resultText, systemImage: row.resultIcon)
							.foregroundStyle(row.resultColor)
					}
					.width(min: 90, ideal: 105)
				}
				.contextMenu(forSelectionType: UUID.self) { selectedIDs in
					if let row = row(for: selectedIDs, in: rows) {
						Button("Connect Again") {
							reconnect(row.entry)
						}
					}
				} primaryAction: { selectedIDs in
					if let row = row(for: selectedIDs, in: rows) {
						reconnect(row.entry)
					}
				}
				.overlay {
					if rows.isEmpty {
						if query.isEmpty {
							ContentUnavailableView(
								"No Connection History",
								systemImage: "clock.arrow.circlepath",
								description: Text(
									"Connections will appear here after you open a host."
								)
							)
						} else {
							ContentUnavailableView.search(text: query)
						}
					}
				}

				Divider()
				HStack(spacing: 8) {
					Image(systemName: "lock.shield")
					Text("Stored locally on this Mac. Terminal contents are never recorded.")
						.lineLimit(1)
					Spacer()
					Button("Clear History…", role: .destructive) {
						showingClearConfirmation = true
					}
					.disabled(historyStore.entries.isEmpty)
				}
				.font(.caption)
				.foregroundStyle(.secondary)
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
			}
		}
		.searchable(text: $query, prompt: "Search hosts, addresses, or results")
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button {
					if let entry = selectedEntry {
						reconnect(entry)
					}
				} label: {
					Label("Connect Again", systemImage: "arrow.clockwise")
				}
				.disabled(selectedEntry == nil)
				.help("Open a new connection using this destination")
			}
		}
		.alert("Clear Connection History?", isPresented: $showingClearConfirmation) {
			Button("Clear History", role: .destructive) {
				do {
					try historyStore.clear()
					selection.removeAll()
				} catch {
					errorMessage = error.localizedDescription
				}
			}
			Button("Cancel", role: .cancel) { }
		} message: {
			Text("This removes all locally stored connection metadata. This cannot be undone.")
		}
		.alert(
			"Unable to Update History",
			isPresented: Binding(
				get: { errorMessage != nil },
				set: { if !$0 { errorMessage = nil } }
			),
			presenting: errorMessage
		) { _ in
			Button("OK") { errorMessage = nil }
		} message: { message in
			Text(message)
		}
		.frame(minWidth: 680, minHeight: 360)
	}

	private var selectedEntry: SessionHistoryEntry? {
		guard let id = selection.first else { return nil }
		return historyStore.entries.first(where: { $0.id == id })
	}

	private func visibleRows(now: Date) -> [SessionHistoryRow] {
		let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
		let rows = historyStore.entries.map {
			SessionHistoryRow(entry: $0, now: now)
		}
		let filtered = normalizedQuery.isEmpty ? rows : rows.filter {
			$0.searchText.localizedCaseInsensitiveContains(normalizedQuery)
		}
		return filtered.sorted(using: sortOrder)
	}

	private func row(
		for selectedIDs: Set<UUID>,
		in rows: [SessionHistoryRow]
	) -> SessionHistoryRow? {
		guard let id = selectedIDs.first else { return nil }
		return rows.first(where: { $0.id == id })
	}

	private func reconnect(_ entry: SessionHistoryEntry) {
		let host: SSHHost
		let authenticationMode: SSHAuthenticationMode
		if let savedHostID = entry.host.savedHostID,
		   let savedHost = sessionStore.hosts.first(where: { $0.id == savedHostID }) {
			host = savedHost
			authenticationMode = .configuredCredential
		} else {
			host = SSHHost(
				id: entry.host.savedHostID ?? UUID(),
				name: entry.host.displayName,
				hostname: entry.host.hostname,
				port: entry.host.port,
				username: entry.host.username,
				credential: .agent
			)
			authenticationMode = .interactive
		}
		let tabID = sessionStore.openTab(
			host: host,
			installTerminfo: preferences.installTerminfoEnabled,
			authenticationMode: authenticationMode
		)
		openWindow(value: tabID)
	}
}

private struct SessionHistoryRow: Identifiable {
	let entry: SessionHistoryEntry
	let now: Date

	var id: UUID { entry.id }
	var hostName: String { entry.host.displayName }

	var address: String {
		let hostname = entry.host.hostname.contains(":")
			? "[\(entry.host.hostname)]"
			: entry.host.hostname
		return "\(entry.host.username)@\(hostname):\(entry.host.port)"
	}

	var startedAt: Date { entry.startedAt }

	var durationSeconds: TimeInterval {
		switch entry.state {
		case .ended(_, let endedAt, _):
			return max(0, endedAt.timeIntervalSince(entry.startedAt))
		case .connecting, .connected:
			return max(0, now.timeIntervalSince(entry.startedAt))
		}
	}

	var durationText: String {
		let totalSeconds = Int(durationSeconds.rounded(.down))
		let hours = totalSeconds / 3_600
		let minutes = (totalSeconds % 3_600) / 60
		let seconds = totalSeconds % 60
		if hours > 0 {
			return String(format: "%d:%02d:%02d", hours, minutes, seconds)
		}
		return String(format: "%d:%02d", minutes, seconds)
	}

	var resultText: String {
		switch entry.state {
		case .connecting: "Connecting"
		case .connected: "Connected"
		case .ended(_, _, let outcome):
			switch outcome {
			case .completed: "Completed"
			case .failed: "Failed"
			case .cancelled: "Cancelled"
			case .interrupted: "Interrupted"
			}
		}
	}

	var resultIcon: String {
		switch entry.state {
		case .connecting: "ellipsis.circle"
		case .connected: "checkmark.circle.fill"
		case .ended(_, _, let outcome):
			switch outcome {
			case .completed: "checkmark.circle"
			case .failed: "xmark.circle"
			case .cancelled: "minus.circle"
			case .interrupted: "exclamationmark.circle"
			}
		}
	}

	var resultColor: Color {
		switch entry.state {
		case .connecting: .secondary
		case .connected: .green
		case .ended(_, _, let outcome):
			switch outcome {
			case .completed: .secondary
			case .failed: .red
			case .cancelled: .secondary
			case .interrupted: .orange
			}
		}
	}

	var searchText: String {
		"\(hostName) \(address) \(resultText)"
	}
}
