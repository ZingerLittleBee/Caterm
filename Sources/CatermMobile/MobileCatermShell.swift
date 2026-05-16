import FileTransferStore
import SnippetSyncClient
import SSHCommandBuilder
import SwiftUI

public struct MobileCatermShell: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@State private var hosts: [SSHHost]
	@State private var snippets: [Snippet]
	@State private var remoteEntries: [RemoteEntry]
	@State private var transfers: [TransferTask]
	@State private var selection: MobileShellSelection?
	@State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
	@State private var showingAddHost = false

	public init(
		hosts: [SSHHost] = [],
		snippets: [Snippet] = [],
		remoteEntries: [RemoteEntry] = [],
		transfers: [TransferTask] = []
	) {
		_hosts = State(initialValue: hosts)
		_snippets = State(initialValue: snippets)
		_remoteEntries = State(initialValue: remoteEntries)
		_transfers = State(initialValue: transfers)
		_selection = State(initialValue: hosts.first.map { .host($0.id) })
	}

	public var body: some View {
		Group {
			if horizontalSizeClass == .compact {
				MobileCompactShell(
					hosts: $hosts,
					snippets: $snippets,
					remoteEntries: $remoteEntries,
					transfers: $transfers
				)
			} else {
				NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
					MobileShellSidebar(
						hosts: hosts,
						selection: $selection,
						showingAddHost: $showingAddHost
					)
				} detail: {
					MobileShellDetail(
						selection: $selection,
						hosts: $hosts,
						snippets: $snippets,
						remoteEntries: $remoteEntries,
						transfers: $transfers
					)
				}
				.sheet(isPresented: $showingAddHost) {
					NavigationStack {
						MobileHostFormView(mode: .add, allHosts: hosts) { payload in
							hosts.append(payload.host)
							selection = .host(payload.host.id)
							showingAddHost = false
						}
					}
				}
			}
		}
	}
}

private enum MobileShellSelection: Hashable {
	case host(UUID)
	case terminal(UUID)
	case credential(UUID)
	case snippets
	case files
	case settings
}

private struct MobileCompactShell: View {
	@Binding var hosts: [SSHHost]
	@Binding var snippets: [Snippet]
	@Binding var remoteEntries: [RemoteEntry]
	@Binding var transfers: [TransferTask]

	var body: some View {
		TabView {
			NavigationStack {
				MobileHostsView(hosts: $hosts)
			}
			.tabItem { Label("Hosts", systemImage: "server.rack") }

			NavigationStack {
				MobileSnippetsView(snippets: $snippets)
			}
			.tabItem { Label("Snippets", systemImage: "text.cursor") }

			NavigationStack {
				MobileFileBrowserView(entries: remoteEntries, transfers: transfers)
			}
			.tabItem { Label("Files", systemImage: "folder") }

			NavigationStack {
				MobileSettingsView()
			}
			.tabItem { Label("Settings", systemImage: "gearshape") }
		}
	}
}

private struct MobileShellSidebar: View {
	let hosts: [SSHHost]
	@Binding var selection: MobileShellSelection?
	@Binding var showingAddHost: Bool

	var body: some View {
		List(selection: $selection) {
			Section("Hosts") {
				if hosts.isEmpty {
					Label("No hosts", systemImage: "server.rack")
						.foregroundStyle(.secondary)
				} else {
					ForEach(hosts) { host in
						Label(host.name, systemImage: "server.rack")
							.tag(MobileShellSelection.host(host.id))
					}
				}
			}

			Section("Tools") {
				Label("Snippets", systemImage: "text.cursor")
					.tag(MobileShellSelection.snippets)
				Label("Files", systemImage: "folder")
					.tag(MobileShellSelection.files)
				Label("Settings", systemImage: "gearshape")
					.tag(MobileShellSelection.settings)
			}
		}
		.navigationTitle("Caterm")
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button {
					showingAddHost = true
				} label: {
					Image(systemName: "plus")
				}
				.accessibilityLabel("Add Host")
			}
		}
	}
}

private struct MobileShellDetail: View {
	@Binding var selection: MobileShellSelection?
	@Binding var hosts: [SSHHost]
	@Binding var snippets: [Snippet]
	@Binding var remoteEntries: [RemoteEntry]
	@Binding var transfers: [TransferTask]

	var body: some View {
		switch selection {
		case .host(let id):
			if let binding = binding(for: id) {
				MobileHostDetailView(
					host: binding.wrappedValue,
					onConnect: { route in
						switch route {
						case .credentialSetup(let hostId):
							selection = .credential(hostId)
						case .terminalPlaceholder(let hostId):
							selection = .terminal(hostId)
						case .detail(let hostId), .edit(let hostId):
							selection = .host(hostId)
						}
					},
					onDelete: {
						hosts.removeAll { $0.id == id }
					},
					onUpdate: { updated in
						if let index = hosts.firstIndex(where: { $0.id == updated.id }) {
							hosts[index] = updated
						}
					}
				)
			} else {
				ContentUnavailableView("Host Not Found", systemImage: "server.rack")
			}
		case .terminal(let id):
			MobileTerminalPlaceholderView(host: hosts.first { $0.id == id }, snippet: nil)
		case .credential(let id):
			MobileCredentialSetupPlaceholderView(host: hosts.first { $0.id == id })
		case .snippets:
			MobileSnippetsView(snippets: $snippets)
		case .files:
			MobileFileBrowserView(entries: remoteEntries, transfers: transfers)
		case .settings:
			MobileSettingsView()
		case nil:
			MobileHostsView(hosts: $hosts)
		}
	}

	private func binding(for id: UUID) -> Binding<SSHHost>? {
		guard let index = hosts.firstIndex(where: { $0.id == id }) else { return nil }
		return $hosts[index]
	}
}
