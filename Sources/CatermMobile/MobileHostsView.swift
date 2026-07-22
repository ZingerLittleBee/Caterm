import CatermMobileTerminal
import Foundation
import SnippetSyncClient
import SSHCommandBuilder
import SwiftUI

public struct MobileHostsView: View {
	@Binding private var hosts: [SSHHost]
	private let snippets: [Snippet]
	private let terminalPreferences: MobileTerminalPreferences
	@Environment(\.mobileHostSave) private var hostSave
	@Environment(\.mobileHostSyncState) private var syncState
	@Environment(\.mobileTerminalSessionFactory) private var terminalSessionFactory
	@State private var searchText = ""
	@State private var editingHost: SSHHost?
	@State private var pendingDelete: SSHHost?
	@State private var route: MobileHostRoute?

	public init(
		hosts: Binding<[SSHHost]>,
		snippets: [Snippet] = [],
		terminalPreferences: MobileTerminalPreferences = .storedDefaults
	) {
		_hosts = hosts
		self.snippets = snippets
		self.terminalPreferences = terminalPreferences
	}

	public var body: some View {
		List {
			if let syncState, shouldShowSyncStatus(syncState) {
				MobileHostSyncStatusView(state: syncState)
					.listRowInsets(EdgeInsets())
					.listRowSeparator(.hidden)
			}

			if filteredHosts.isEmpty {
				ContentUnavailableView("No Hosts", systemImage: "server.rack")
					.listRowSeparator(.hidden)
			} else {
				ForEach(filteredHosts) { host in
					NavigationLink(value: MobileHostRoute.terminalPlaceholder(host.id)) {
						MobileHostRow(host: host)
					}
					.contextMenu {
						Button {
							editingHost = host
						} label: {
							Label("Edit", systemImage: "pencil")
						}
						Button(role: .destructive) {
							pendingDelete = host
						} label: {
							Label("Delete", systemImage: "trash")
						}
					}
					.swipeActions(edge: .trailing) {
						Button(role: .destructive) {
							pendingDelete = host
						} label: {
							Label("Delete", systemImage: "trash")
						}
						Button {
							editingHost = host
						} label: {
							Label("Edit", systemImage: "pencil")
						}
						.tint(.blue)
					}
				}
			}
		}
		.navigationTitle("Hosts")
		.searchable(text: $searchText, prompt: "Search hosts")
		.navigationDestination(for: MobileHostRoute.self) { route in
			destination(for: route)
		}
		.sheet(item: $editingHost) { host in
			NavigationStack {
				MobileHostFormView(mode: .edit(host), allHosts: hosts) { payload in
					saveHost(payload) {
						editingHost = nil
					}
				}
			}
		}
		.confirmationDialog(
			"Delete \(pendingDelete?.name ?? "")?",
			isPresented: Binding(
				get: { pendingDelete != nil },
				set: { if !$0 { pendingDelete = nil } }
			),
			titleVisibility: .visible
		) {
			Button("Delete Host", role: .destructive) {
				if let host = pendingDelete {
					deleteHost(id: host.id)
				}
				pendingDelete = nil
			}
			Button("Cancel", role: .cancel) {
				pendingDelete = nil
			}
		}
	}

	@MainActor
	static func fallbackSession(for host: SSHHost) async throws -> SSHTerminalSession {
		#if targetEnvironment(simulator)
		let env = ProcessInfo.processInfo.environment
		let password = env["CATERM_SIM_SSH_PASSWORD"]
		let passphrase = env["CATERM_SIM_SSH_PASSPHRASE"]
		#else
		let password: String? = nil
		let passphrase: String? = nil
		#endif
		let keyBlob: Data? = await Task.detached {
			if case let .keyFile(path, _) = host.credential {
				return try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
			}
			return nil
		}.value
		let plan = SSHAuthPlan.make(
			host: host, password: password, keyBlob: keyBlob, passphrase: passphrase)
		let support = (FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? FileManager.default.temporaryDirectory)
			.appendingPathComponent("Caterm", isDirectory: true)
		let knownHosts = MobileKnownHostsStore(
			fileURL: support.appendingPathComponent("known_hosts.json"))
		let transport = NIOSSHTransport(host: host, plan: plan, knownHosts: knownHosts)
		return SSHTerminalSession(host: host, transport: transport)
	}

	@MainActor
	private func makeSession(for host: SSHHost) async throws -> SSHTerminalSession {
		if let terminalSessionFactory {
			return try await terminalSessionFactory.make(host)
		}
		return try await Self.fallbackSession(for: host)
	}

	private func saveHost(
		_ payload: MobileHostDraftPayload,
		onSuccess: @escaping @MainActor () -> Void = {}
	) {
		if let hostSave {
			Task { @MainActor in
				guard await hostSave.save(payload) else { return }
				onSuccess()
			}
		} else if let index = hosts.firstIndex(where: { $0.id == payload.host.id }) {
			hosts[index] = payload.host
			onSuccess()
		} else {
			hosts.append(payload.host)
			onSuccess()
		}
	}

	private func deleteHost(id: UUID) {
		if let hostSave {
			Task { @MainActor in
				_ = await hostSave.deleteHost(id)
			}
		} else {
			hosts.removeAll { $0.id == id }
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

	private func shouldShowSyncStatus(_ state: MobileHostSyncState) -> Bool {
		if case .upToDate = state { return false }
		return true
	}

	@ViewBuilder
	private func destination(for route: MobileHostRoute) -> some View {
		switch route {
		case .detail(let id):
			if let host = hosts.first(where: { $0.id == id }) {
				MobileHostDetailView(
					host: host,
					snippets: snippets,
					terminalPreferences: terminalPreferences,
					onConnect: nil,
					onDelete: { deleteHost(id: id) },
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
					saveHost(payload)
				}
			} else {
				ContentUnavailableView("Host Not Found", systemImage: "server.rack")
			}
		case .credentialSetup(let id):
			MobileCredentialSetupPlaceholderView(host: hosts.first { $0.id == id })
		case .terminalPlaceholder(let id):
			if let host = hosts.first(where: { $0.id == id }) {
				#if canImport(UIKit)
				MobileTerminalSessionView(
					initialHost: host,
					hosts: hosts,
					snippets: snippets.map {
						TerminalSnippet(id: $0.id, name: $0.name, command: $0.content)
					},
					preferences: terminalPreferences
				) {
					try await makeSession(for: $0)
				}
				#else
				MobileTerminalPlaceholderView(host: host, snippet: nil)
				#endif
			} else {
				ContentUnavailableView("Host Not Found", systemImage: "server.rack")
			}
		}
	}
}

struct MobileHostDetailView: View {
	let host: SSHHost
	let snippets: [Snippet]
	let terminalPreferences: MobileTerminalPreferences
	let onConnect: ((MobileHostRoute) -> Void)?
	let onDelete: () -> Void
	let onUpdate: (SSHHost) -> Void
	@Environment(\.mobileHostSave) private var hostSave
	@Environment(\.mobileTerminalSessionFactory) private var terminalSessionFactory
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
					if let hostSave {
						Task { @MainActor in
							guard await hostSave.save(payload) else { return }
							showingEdit = false
						}
					} else {
						onUpdate(payload.host)
						showingEdit = false
					}
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
			if id == host.id {
				#if canImport(UIKit)
					MobileTerminalSessionView(
						initialHost: host,
						hosts: [host],
						snippets: snippets.map {
							TerminalSnippet(id: $0.id, name: $0.name, command: $0.content)
						},
						preferences: terminalPreferences
					) {
						if let terminalSessionFactory {
							return try await terminalSessionFactory.make($0)
						}
						return try await MobileHostsView.fallbackSession(for: $0)
					}
				#else
				MobileTerminalPlaceholderView(host: host, snippet: nil)
				#endif
			} else {
				ContentUnavailableView("Host Not Found", systemImage: "server.rack")
			}
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
