import SSHCommandBuilder
import SwiftUI

public struct MobileHostsView: View {
	@Binding private var hosts: [SSHHost]
	@State private var searchText = ""
	@State private var showingAddHost = false
	@State private var route: MobileHostRoute?

	public init(hosts: Binding<[SSHHost]>) {
		_hosts = hosts
	}

	public var body: some View {
		List {
			if filteredHosts.isEmpty {
				ContentUnavailableView("No Hosts", systemImage: "server.rack")
					.listRowSeparator(.hidden)
			} else {
				ForEach(filteredHosts) { host in
					NavigationLink(value: MobileHostRoute.detail(host.id)) {
						MobileHostRow(host: host)
					}
					.swipeActions(edge: .trailing) {
						Button(role: .destructive) {
							hosts.removeAll { $0.id == host.id }
						} label: {
							Label("Delete", systemImage: "trash")
						}
					}
				}
			}
		}
		.navigationTitle("Hosts")
		.searchable(text: $searchText, prompt: "Search hosts")
		.navigationDestination(for: MobileHostRoute.self) { route in
			destination(for: route)
		}
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
		.sheet(isPresented: $showingAddHost) {
			NavigationStack {
				MobileHostFormView(mode: .add, allHosts: hosts) { payload in
					hosts.append(payload.host)
					showingAddHost = false
				}
			}
		}
	}

	private var filteredHosts: [SSHHost] {
		let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return hosts }
		let needle = trimmed.lowercased()
		return hosts.filter {
			$0.name.lowercased().contains(needle)
				|| $0.hostname.lowercased().contains(needle)
				|| $0.username.lowercased().contains(needle)
		}
	}

	@ViewBuilder
	private func destination(for route: MobileHostRoute) -> some View {
		switch route {
		case .detail(let id):
			if let host = hosts.first(where: { $0.id == id }) {
				MobileHostDetailView(
					host: host,
					onConnect: nil,
					onDelete: { hosts.removeAll { $0.id == id } },
					onUpdate: { updated in
						if let index = hosts.firstIndex(where: { $0.id == updated.id }) {
							hosts[index] = updated
						}
					}
				)
			} else {
				ContentUnavailableView("Host Not Found", systemImage: "server.rack")
			}
		case .edit(let id):
			if let host = hosts.first(where: { $0.id == id }) {
				MobileHostFormView(mode: .edit(host), allHosts: hosts) { payload in
					if let index = hosts.firstIndex(where: { $0.id == id }) {
						hosts[index] = payload.host
					}
				}
			} else {
				ContentUnavailableView("Host Not Found", systemImage: "server.rack")
			}
		case .credentialSetup(let id):
			MobileCredentialSetupPlaceholderView(host: hosts.first { $0.id == id })
		case .terminalPlaceholder(let id):
			MobileTerminalPlaceholderView(host: hosts.first { $0.id == id }, snippet: nil)
		}
	}
}

struct MobileHostDetailView: View {
	let host: SSHHost
	let onConnect: ((MobileHostRoute) -> Void)?
	let onDelete: () -> Void
	let onUpdate: (SSHHost) -> Void
	@State private var showingDeleteConfirmation = false
	@State private var showingEdit = false
	@State private var localRoute: MobileHostRoute?

	var body: some View {
		List {
			Section {
				VStack(alignment: .leading, spacing: 8) {
					Label(host.name, systemImage: "server.rack")
						.font(.headline)
					Text("\(host.username)@\(host.hostname):\(host.port)")
						.font(.subheadline)
						.foregroundStyle(.secondary)
						.textSelection(.enabled)
				}
				.padding(.vertical, 4)
			}

			Section {
				Button {
					let route = MobileHostActions.connectRoute(
						for: host,
						needsCredentialSetup: false
					)
					if let onConnect {
						onConnect(route)
					} else {
						localRoute = route
					}
				} label: {
					Label("Connect", systemImage: "terminal")
				}

				Button {
					showingEdit = true
				} label: {
					Label("Edit", systemImage: "pencil")
				}

				Button(role: .destructive) {
					showingDeleteConfirmation = true
				} label: {
					Label("Delete", systemImage: "trash")
				}
			}

			if !host.forwards.isEmpty {
				Section("Port Forwards") {
					ForEach(host.forwards) { forward in
						Text(summary(for: forward))
					}
				}
			}
		}
		.navigationTitle(host.name)
		.navigationDestination(item: $localRoute) { route in
			routeDestination(route)
		}
		.sheet(isPresented: $showingEdit) {
			NavigationStack {
				MobileHostFormView(mode: .edit(host), allHosts: [host]) { payload in
					onUpdate(payload.host)
					showingEdit = false
				}
			}
		}
		.confirmationDialog("Delete \(host.name)?", isPresented: $showingDeleteConfirmation) {
			Button("Delete Host", role: .destructive, action: onDelete)
			Button("Cancel", role: .cancel) { }
		}
	}

	private func summary(for forward: PortForward) -> String {
		let bind = [forward.bindAddress, String(forward.bindPort)]
			.compactMap { $0 }
			.joined(separator: ":")
		switch forward.kind {
		case .dynamic:
			return "Dynamic \(bind)"
		case .local:
			return "Local \(bind) -> \(forward.remoteHost ?? ""):\(forward.remotePort ?? 0)"
		case .remote:
			return "Remote \(bind) -> \(forward.remoteHost ?? ""):\(forward.remotePort ?? 0)"
		}
	}

	@ViewBuilder
	private func routeDestination(_ route: MobileHostRoute) -> some View {
		switch route {
		case .credentialSetup(let id):
			MobileCredentialSetupPlaceholderView(host: id == host.id ? host : nil)
		case .terminalPlaceholder(let id):
			MobileTerminalPlaceholderView(host: id == host.id ? host : nil, snippet: nil)
		case .detail, .edit:
			EmptyView()
		}
	}
}

struct MobileHostRow: View {
	let host: SSHHost

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(host.name)
				.font(.headline)
			Text("\(host.username)@\(host.hostname)")
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.lineLimit(1)
		}
		.accessibilityElement(children: .combine)
	}
}
