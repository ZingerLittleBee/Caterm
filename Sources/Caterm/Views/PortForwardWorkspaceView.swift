import HostSyncStore
import SessionStore
import SSHCommandBuilder
import SwiftUI
import WorkspaceCore

enum PortForwardWorkspaceWindow {
	static let id = "port-forwarding"
}

struct PortForwardWorkspaceRow: Identifiable {
	let hostID: UUID
	let hostName: String
	let hostAddress: String
	let forward: PortForward

	var id: UUID { forward.id }
	var ruleName: String {
		forward.label?.nilIfEmpty ?? "\(kindText) forwarding"
	}

	var kindText: String {
		switch forward.kind {
		case .local: "Local"
		case .remote: "Remote"
		case .dynamic: "Dynamic"
		}
	}

	var listenAddress: String {
		"\(forward.bindAddress?.nilIfEmpty ?? "localhost"):\(forward.bindPort)"
	}

	var destination: String {
		guard forward.kind != .dynamic else { return "SOCKS proxy" }
		return "\(forward.remoteHost ?? ""):\(forward.remotePort ?? 0)"
	}

	var requiredText: String {
		forward.required ? "Required" : "Optional"
	}

	var searchText: String {
		"\(ruleName) \(hostName) \(hostAddress) \(kindText) \(listenAddress) \(destination) \(requiredText)"
	}
}

enum PortForwardWorkspaceModel {
	static func rows(
		hosts: [SSHHost],
		query: String
	) -> [PortForwardWorkspaceRow] {
		let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
		let rows = hosts.flatMap { host in
			host.forwards.map { forward in
				PortForwardWorkspaceRow(
					hostID: host.id,
					hostName: host.name,
					hostAddress: "\(host.username)@\(host.hostname):\(host.port)",
					forward: forward
				)
			}
		}
		guard !normalizedQuery.isEmpty else { return rows }
		return rows.filter {
			$0.searchText.localizedCaseInsensitiveContains(normalizedQuery)
		}
	}
}

struct PortForwardWorkspaceView: View {
	@EnvironmentObject private var store: SessionStore
	@EnvironmentObject private var preferences: SyncPreferences
	@EnvironmentObject private var workspaceCoordinator: WorkspaceCoordinator
	@Environment(\.openWindow) private var openWindow
	@State private var selection: Set<UUID> = []
	@State private var query = ""
	@State private var editorRequest: EditorRequest?
	@State private var sortOrder = [
		KeyPathComparator(\PortForwardWorkspaceRow.hostName)
	]
	@State private var connectionErrorMessage: String?

	private struct EditorRequest: Identifiable {
		let id = UUID()
		let hostID: UUID
		let addingNewRule: Bool
	}

	var body: some View {
		let ruleCount = store.hosts.reduce(0) { $0 + $1.forwards.count }
		let rows = PortForwardWorkspaceModel.rows(hosts: store.hosts, query: query)
			.sorted(using: sortOrder)
		VStack(spacing: 0) {
			Table(rows, selection: $selection, sortOrder: $sortOrder) {
				TableColumn("Rule", value: \.ruleName)
					.width(min: 100, ideal: 130)
				TableColumn("Host", value: \.hostName)
					.width(min: 100, ideal: 120)
				TableColumn("Type", value: \.kindText)
					.width(min: 55, ideal: 65)
				TableColumn("Listen", value: \.listenAddress)
					.width(min: 120, ideal: 140)
				TableColumn("Destination", value: \.destination)
					.width(min: 120, ideal: 155)
				TableColumn("Policy", value: \.requiredText)
					.width(min: 60, ideal: 70)
			}
			.contextMenu(forSelectionType: UUID.self) { selectedIDs in
				if let row = row(for: selectedIDs, in: rows) {
					Button("Connect Host") { connect(row.hostID) }
					Button("Edit Forwarding Rules…") { edit(row.hostID) }
				}
			} primaryAction: { selectedIDs in
				if let row = row(for: selectedIDs, in: rows) {
					edit(row.hostID)
				}
			}
			.overlay {
				if rows.isEmpty {
					if query.isEmpty {
						ContentUnavailableView(
							"No Port Forwarding Rules",
							systemImage: "arrow.left.arrow.right",
							description: Text(
								"Add a rule to a saved host, then connect that host to activate it."
							)
						)
					} else {
						ContentUnavailableView.search(text: query)
					}
				}
			}
			Divider()
			HStack(spacing: 8) {
				Image(systemName: "info.circle")
				Text("Forwarding rules activate when you connect to their host.")
				Spacer()
				Text("\(ruleCount) \(ruleCount == 1 ? "rule" : "rules")")
			}
			.font(.caption)
			.foregroundStyle(.secondary)
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
		}
		.searchable(text: $query, prompt: "Search hosts, ports, or destinations")
		.toolbar {
			ToolbarItemGroup(placement: .primaryAction) {
				Button {
					if let row = selectedRow {
						connect(row.hostID)
					}
				} label: {
					Label("Connect Host", systemImage: "play.fill")
				}
				.disabled(selectedRow == nil)
				Menu {
					ForEach(store.hosts) { host in
						Button(host.name) {
							editorRequest = EditorRequest(
								hostID: host.id,
								addingNewRule: true
							)
						}
					}
				} label: {
					Label("New Forwarding", systemImage: "plus")
				}
				.disabled(store.hosts.isEmpty)
				Button {
					if let row = selectedRow { edit(row.hostID) }
				} label: {
					Label("Edit Rules", systemImage: "slider.horizontal.3")
				}
				.disabled(selectedRow == nil)
			}
		}
		.sheet(item: $editorRequest) { request in
			if let host = store.hosts.first(where: { $0.id == request.hostID }) {
				PortForwardEditorSheet(
					host: host,
					addingNewRule: request.addingNewRule
				) { forwards in
					guard var current = store.hosts.first(where: { $0.id == host.id }) else {
						throw PortForwardWorkspaceError.hostWasDeleted
					}
					current.forwards = forwards
					try store.updateHost(current)
				}
			} else {
				ContentUnavailableView(
					"Host No Longer Exists",
					systemImage: "questionmark.folder"
				)
				.frame(width: 440, height: 240)
			}
		}
		.alert(
			"Unable to Open Workspace",
			isPresented: Binding(
				get: { connectionErrorMessage != nil },
				set: { if !$0 { connectionErrorMessage = nil } }
			),
			presenting: connectionErrorMessage
		) { _ in
			Button("OK") { connectionErrorMessage = nil }
		} message: { message in
			Text(message)
		}
		.frame(minWidth: 760, minHeight: 420)
	}

	private var selectedRow: PortForwardWorkspaceRow? {
		guard let id = selection.first else { return nil }
		return PortForwardWorkspaceModel.rows(hosts: store.hosts, query: "")
			.first(where: { $0.id == id })
	}

	private func row(
		for selectedIDs: Set<UUID>,
		in rows: [PortForwardWorkspaceRow]
	) -> PortForwardWorkspaceRow? {
		guard let id = selectedIDs.first else { return nil }
		return rows.first(where: { $0.id == id })
	}

	private func edit(_ hostID: UUID) {
		editorRequest = EditorRequest(hostID: hostID, addingNewRule: false)
	}

	private func connect(_ hostID: UUID) {
		guard let host = store.hosts.first(where: { $0.id == hostID }) else { return }
		do {
			let workspace = try workspaceCoordinator.openSavedHost(
				host,
				installTerminfo: preferences.installTerminfoEnabled
			)
			openWindow(value: WorkspaceWindowState.workspace(workspace))
		} catch {
			connectionErrorMessage = error.localizedDescription
		}
	}
}

private enum PortForwardWorkspaceError: LocalizedError {
	case hostWasDeleted

	var errorDescription: String? {
		"The host was deleted before its forwarding rules could be saved."
	}
}

private struct PortForwardEditorSheet: View {
	let host: SSHHost
	let onSave: ([PortForward]) throws -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var forwards: [PortForward]
	@State private var errorMessage: String?

	init(
		host: SSHHost,
		addingNewRule: Bool,
		onSave: @escaping ([PortForward]) throws -> Void
	) {
		self.host = host
		self.onSave = onSave
		var initialForwards = host.forwards
		if addingNewRule {
			initialForwards.append(Self.makeDefaultForward(existing: initialForwards))
		}
		_forwards = State(initialValue: initialForwards)
	}

	var body: some View {
		VStack(spacing: 0) {
			VStack(alignment: .leading, spacing: 4) {
				Text("Port Forwarding for \(host.name)")
					.font(.title2.weight(.semibold))
				Text("\(host.username)@\(host.hostname):\(host.port)")
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(20)

			Divider()
			ScrollView {
				VStack(spacing: 12) {
					ForEach($forwards) { $forward in
						PortForwardRuleEditor(
							forward: $forward,
							onDelete: {
								forwards.removeAll { $0.id == forward.id }
							}
						)
					}
					Button {
						forwards.append(Self.makeDefaultForward(existing: forwards))
					} label: {
						Label("Add Port Forward", systemImage: "plus")
					}
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				.padding(20)
			}
			Divider()
			HStack {
				Button("Cancel") { dismiss() }
					.keyboardShortcut(.cancelAction)
				Spacer()
				Button("Save") {
					do {
						try onSave(forwards)
						dismiss()
					} catch {
						errorMessage = error.localizedDescription
					}
				}
				.keyboardShortcut(.defaultAction)
				.disabled((try? PortForward.validateCollection(forwards)) == nil)
			}
			.padding(.horizontal, 20)
			.padding(.vertical, 14)
		}
		.frame(width: 600, height: 620)
		.alert(
			"Unable to Save Port Forwarding",
			isPresented: Binding(
				get: { errorMessage != nil },
				set: { if !$0 { errorMessage = nil } }
			),
			presenting: errorMessage
		) { _ in
			Button("OK") { errorMessage = nil }
		} message: { Text($0) }
	}

	private static func makeDefaultForward(existing: [PortForward]) -> PortForward {
		let usedPorts = Set(existing.map(\.bindPort))
		let bindPort = (8080...65535).first(where: { !usedPorts.contains($0) }) ?? 8080
		return PortForward(
			kind: .local,
			bindPort: bindPort,
			remoteHost: "localhost",
			remotePort: 8080
		)
	}
}

private extension String {
	var nilIfEmpty: String? {
		isEmpty ? nil : self
	}
}
