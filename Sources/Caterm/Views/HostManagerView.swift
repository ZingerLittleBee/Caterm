import HostSyncStore
import SessionStore
import SSHCommandBuilder
import SwiftUI
import WorkspaceCore

enum HostManagerWindow {
	static let id = "host-manager"
}

private enum HostManagerScope: Hashable {
	case all
	case ungrouped
	case group([String])
	case tag(String)
}

private struct HostManagerRow: Identifiable {
	let host: SSHHost

	var id: UUID { host.id }
	var name: String { host.name }
	var destination: String { "\(host.username)@\(host.hostname):\(host.port)" }
	var group: String { host.organization.groupDisplayName ?? "Ungrouped" }
	var tags: String {
		host.organization.tags.isEmpty
			? "No tags"
			: host.organization.tags.joined(separator: ", ")
	}
}

struct HostManagerView: View {
	@EnvironmentObject private var store: SessionStore
	@EnvironmentObject private var preferences: SyncPreferences
	@EnvironmentObject private var workspaceCoordinator: WorkspaceCoordinator
	@Environment(\.openWindow) private var openWindow
	@State private var scope: HostManagerScope? = .all
	@State private var selection: Set<UUID> = []
	@State private var query = ""
	@State private var editorRequest: HostOrganizationEditorRequest?
	@State private var pendingDelete: Set<UUID>?
	@State private var errorMessage: String?
	@State private var sortOrder = [KeyPathComparator(\HostManagerRow.name)]

	var body: some View {
		let groups = HostOrganizationQuery.groups(in: store.hosts)
		let tags = HostOrganizationQuery.tags(in: store.hosts)
		let visibleHosts = filteredHosts.sorted {
			$0.name.localizedStandardCompare($1.name) == .orderedAscending
		}
		let rows = visibleHosts.map(HostManagerRow.init).sorted(using: sortOrder)

		NavigationSplitView {
			List(selection: $scope) {
				Section {
					Label("All Hosts", systemImage: "server.rack")
						.tag(HostManagerScope.all)
					Label("Ungrouped", systemImage: "tray")
						.tag(HostManagerScope.ungrouped)
				} header: {
					Text("Library")
				}
				if !groups.isEmpty {
					Section("Groups") {
						ForEach(groups, id: \.self) { path in
							Label(
								path.joined(separator: " / "),
								systemImage: "folder"
							)
							.tag(HostManagerScope.group(path))
						}
					}
				}
				if !tags.isEmpty {
					Section("Tags") {
						ForEach(tags, id: \.self) { tag in
							Label(tag, systemImage: "tag")
								.tag(HostManagerScope.tag(tag))
						}
					}
				}
			}
			.navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 270)
		} detail: {
			VStack(spacing: 0) {
				Table(rows, selection: $selection, sortOrder: $sortOrder) {
					TableColumn("Host", value: \.name) { row in
						Label {
							Text(row.name)
						} icon: {
							Image(systemName: hostIconName(for: row.host))
								.foregroundStyle(.secondary)
						}
					}
					.width(min: 130, ideal: 180)
					TableColumn("Destination", value: \.destination)
						.width(min: 190, ideal: 240)
					TableColumn("Group", value: \.group)
						.width(min: 120, ideal: 160)
					TableColumn("Tags", value: \.tags)
						.width(min: 140, ideal: 210)
				}
				.contextMenu(forSelectionType: UUID.self) { selectedIDs in
					if selectedIDs.count == 1 {
						Button("Connect") { connect(selectedIDs.first) }
						Button("Edit Organization…") {
							presentEditor(.edit, selectedIDs: selectedIDs)
						}
						Divider()
					}
					organizationActions(for: selectedIDs)
					Divider()
					Button("Delete…", role: .destructive) {
						pendingDelete = selectedIDs
					}
				} primaryAction: { selectedIDs in
					if selectedIDs.count == 1 { connect(selectedIDs.first) }
				}
				.overlay {
					if rows.isEmpty {
						if store.hosts.isEmpty {
							ContentUnavailableView(
								"No Hosts",
								systemImage: "server.rack",
								description: Text("Add a host from the main Caterm window.")
							)
						} else if !query.isEmpty {
							ContentUnavailableView.search(text: query)
						} else {
							ContentUnavailableView(
								"No Hosts in This Collection",
								systemImage: "folder"
							)
						}
					}
				}
				.onChange(of: rows.map(\.id)) { _, visibleIDs in
					selection.formIntersection(Set(visibleIDs))
				}
				Divider()
				HStack(spacing: 8) {
					Image(systemName: "info.circle")
					Text(selectionSummary)
					Spacer()
					Text("\(rows.count) \(rows.count == 1 ? "host" : "hosts")")
				}
				.font(.caption)
				.foregroundStyle(.secondary)
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
			}
			.searchable(text: $query, prompt: "Search hosts, groups, or tags")
			.toolbar { toolbarContent }
		}
		.sheet(item: $editorRequest) { request in
			HostOrganizationEditorSheet(
				request: request,
				existingGroups: groups,
				existingTags: tags
			) { result in
				Task {
					await apply(result, to: request.selectedIDs)
				}
			}
		}
		.confirmationDialog(
			deleteTitle,
			isPresented: Binding(
				get: { pendingDelete != nil },
				set: { if !$0 { pendingDelete = nil } }
			),
			titleVisibility: .visible
		) {
			Button("Delete", role: .destructive) { deletePendingHosts() }
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("This also removes the hosts' local credentials. This action cannot be undone.")
		}
		.alert(
			"Host Manager Error",
			isPresented: Binding(
				get: { errorMessage != nil },
				set: { if !$0 { errorMessage = nil } }
			),
			presenting: errorMessage
		) { _ in
			Button("OK") { errorMessage = nil }
		} message: { Text($0) }
		.frame(minWidth: 900, minHeight: 500)
	}

	@ToolbarContentBuilder
	private var toolbarContent: some ToolbarContent {
		ToolbarItemGroup(placement: .primaryAction) {
			Button { connect(selection.first) } label: {
				Label("Connect", systemImage: "play.fill")
			}
			.disabled(selection.count != 1)
			Button {
				presentEditor(.edit, selectedIDs: selection)
			} label: {
				Label("Edit Organization", systemImage: "pencil")
			}
			.disabled(selection.count != 1)
			Menu {
				organizationActions(for: selection)
			} label: {
				Label("Organize", systemImage: "folder.badge.gearshape")
			}
			.disabled(selection.isEmpty)
			Button(role: .destructive) {
				pendingDelete = selection
			} label: {
				Label("Delete", systemImage: "trash")
			}
			.disabled(selection.isEmpty)
		}
	}

	@ViewBuilder
	private func organizationActions(for selectedIDs: Set<UUID>) -> some View {
		Button("Set Group…") { presentEditor(.setGroup, selectedIDs: selectedIDs) }
		Button("Add Tags…") { presentEditor(.addTags, selectedIDs: selectedIDs) }
		Button("Remove Tags…") { presentEditor(.removeTags, selectedIDs: selectedIDs) }
	}

	private var filteredHosts: [SSHHost] {
		let filter: (group: [String]?, tag: String?) = switch scope ?? .all {
		case .all: (nil, nil)
		case .ungrouped: ([], nil)
		case .group(let path): (path, nil)
		case .tag(let tag): (nil, tag)
		}
		return HostOrganizationQuery.filter(
			store.hosts, query: query,
			groupPath: filter.group, tag: filter.tag
		)
	}

	private var selectionSummary: String {
		selection.isEmpty
			? "Select hosts to organize them in bulk."
			: "\(selection.count) selected"
	}

	private var deleteTitle: String {
		let count = pendingDelete?.count ?? 0
		return count == 1 ? "Delete this host?" : "Delete \(count) hosts?"
	}

	private func connect(_ hostID: UUID?) {
		guard let hostID,
		      let host = store.hosts.first(where: { $0.id == hostID }) else { return }
		do {
			let workspace = try workspaceCoordinator.openSavedHost(
				host,
				installTerminfo: preferences.installTerminfoEnabled
			)
			openWindow(value: WorkspaceWindowState.workspace(workspace))
		} catch {
			errorMessage = error.localizedDescription
		}
	}

	private func presentEditor(
		_ mode: HostOrganizationEditorMode,
		selectedIDs: Set<UUID>
	) {
		guard !selectedIDs.isEmpty else { return }
		let initial = selectedIDs.count == 1
			? store.hosts.first(where: { selectedIDs.contains($0.id) })?.organization
			: nil
		editorRequest = HostOrganizationEditorRequest(
			mode: mode, selectedIDs: selectedIDs, initial: initial
		)
	}

	private func apply(
		_ result: HostOrganizationEditorResult,
		to selectedIDs: Set<UUID>
	) async {
		do {
			let updatedHosts = store.hosts.compactMap { host -> SSHHost? in
				guard selectedIDs.contains(host.id) else { return nil }
				var updated = host
				updated.organization = result.apply(to: host.organization)
				return updated
			}
			try await store.updateHosts(updatedHosts)
			editorRequest = nil
		} catch {
			errorMessage = error.localizedDescription
		}
	}

	private func deletePendingHosts() {
		guard let ids = pendingDelete else { return }
		pendingDelete = nil
		Task { @MainActor in
			do {
				for id in ids { try await store.deleteHost(id: id) }
				selection.subtract(ids)
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}
}
