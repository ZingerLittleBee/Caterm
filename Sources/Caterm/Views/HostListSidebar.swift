import AppKit
import HostKeyProvisioning
import HostSyncStore
import SessionStore
import SSHCommandBuilder
import SwiftUI
import WorkspaceCore

enum HostCredentialEditRoute: Equatable {
	case preserveCurrent
	case transact(forceSourceCommit: Bool)
}

enum HostCredentialEditRouting {
	static func route(
		initial: CredentialSource,
		current: CredentialSource,
		updated: CredentialSource,
		hasSecret: Bool,
		hasKeyMaterial: Bool
	) -> HostCredentialEditRoute {
		if hasSecret || hasKeyMaterial {
			return .transact(forceSourceCommit: current != updated)
		}
		guard updated != initial, updated != current else {
			return .preserveCurrent
		}
		return .transact(forceSourceCommit: true)
	}
}

/// Sidebar listing the user's saved hosts. Provides:
/// - Add (toolbar + ⌘T notification)
/// - Edit (context menu)
/// - Delete (context menu)
/// - Connect (context menu / double-click) — delegates the new Workspace shell
///   to the owning window via `onOpenWorkspace`. A LandingView swaps its scene
///   value in place; a MainWindow opens a sibling native tab.
///   This avoids the previous behavior of always spawning a new window
///   and leaving the original Landing window around as a blank tab.
struct HostListSidebar: View {
	@EnvironmentObject var store: SessionStore
	@EnvironmentObject var syncStore: HostSyncStore       // NEW (v1.4)
	@EnvironmentObject var preferences: SyncPreferences   // NEW (v1.4)
	@EnvironmentObject var workspaceCoordinator: WorkspaceCoordinator
	@Environment(\.openWindow) private var openWindow
	let onOpenWorkspace: (Workspace) -> Void
	@State private var selectedHostId: UUID?
	@State private var showingAddSheet = false
	@State private var editingHost: SSHHost?
	@State private var errorMessage: String?
	@State private var pendingCredentialHost: SSHHost?
	@State private var pendingFanoutDelete: PendingFanoutDelete?
	@State private var hostQuery = ""
	@State private var hostWindow: NSWindow?

	private struct PendingFanoutDelete: Identifiable {
		let host: SSHHost
		let dependents: [SSHHost]
		var id: UUID { host.id }
	}

	var body: some View {
		let chainResolver = ChainResolver(hosts: store.hosts)
		let visibleHosts = HostSearch.filter(store.hosts, query: hostQuery)
		let quickDestination = visibleHosts.isEmpty
			? QuickConnectParser.parse(hostQuery)
			: nil
		return VStack(spacing: 0) {
			HostSearchField(text: $hostQuery) {
				submitSearch(
					visibleHosts: visibleHosts,
					quickDestination: quickDestination
				)
			}
			.frame(height: 22)
			.padding(.horizontal, 8)
			.padding(.top, 8)
			.padding(.bottom, 6)

			List(selection: $selectedHostId) {
				if let quickDestination {
					QuickConnectRow(destination: quickDestination) {
						connectOnce(quickDestination)
					}
				}
				ForEach(visibleHosts) { host in
					HostRow(
						host: host,
						chainResolution: chainResolver.resolve(host)
					)
						.tag(host.id)
						.contextMenu {
							Button("Connect") { connect(host) }
							Button("Edit") { editingHost = host }
							Divider()
							Button("Delete", role: .destructive) {
								deleteHost(host)
							}
						}
				}
			}
			.overlay {
				GeometryReader { proxy in
					HostListDoubleClickConnector(hosts: visibleHosts) { host in
						connect(host)
					}
					.frame(width: proxy.size.width, height: proxy.size.height)
				}
			}
			.overlay {
				if case .failed = store.hostRepositoryLoadState {
					ContentUnavailableView(
						"Unable to Load Hosts",
						systemImage: "exclamationmark.triangle",
						description: Text(
							"Check the saved Host data and relaunch Caterm."
						)
					)
				} else if store.hostRepositoryLoadState == .loading,
					store.hosts.isEmpty {
					ProgressView("Loading Hosts…")
				} else if store.hosts.isEmpty, quickDestination == nil {
					VStack(spacing: 8) {
						Image(systemName: "server.rack")
							.font(.system(size: 32))
							.foregroundColor(.secondary)
						Text("No hosts yet")
							.foregroundColor(.secondary)
						Text("Click + or press ⌘⇧T to add a host")
							.font(.caption)
							.foregroundColor(.secondary)
						Text("⌘T opens a new tab")
							.font(.caption2)
							.foregroundColor(.secondary)
					}
					.padding()
				} else if visibleHosts.isEmpty, quickDestination == nil {
					ContentUnavailableView.search(text: hostQuery)
				}
			}
			.onChange(of: visibleHosts.map(\.id)) { _, visibleHostIds in
				guard !visibleHostIds.isEmpty,
				      selectedHostId.map({ visibleHostIds.contains($0) }) != true
				else { return }
				selectedHostId = visibleHostIds.first
			}
			.toolbar {
				ToolbarItem(placement: .primaryAction) {
					Menu {
						if !store.hosts.isEmpty {
							Section("Connect to saved host") {
								ForEach(store.hosts) { host in
									Button {
										connect(host)
									} label: {
										Label(
											"\(host.name) — \(host.username)@\(host.hostname)",
											systemImage: hostIconName(for: host)
										)
									}
								}
							}
							Divider()
						}
						Button {
							showingAddSheet = true
						} label: {
							Label("Add New Host…", systemImage: "plus")
						}
					} label: {
						Image(systemName: "plus")
					}
					.menuIndicator(.hidden)
					.help("Connect to a saved host or add a new one (⇧⌘T)")
				}
			}
			.sheet(isPresented: $showingAddSheet) {
				HostFormView(mode: .add) { host, secret, keyMaterial in
					Task { @MainActor in
						do {
							try await store.addHost(host)
							if host.credentialIdentity?.migrationState
								!= .confirmed {
								try await applyCredentialChange(
									hostId: host.id,
									credential: host.credential,
									secret: secret,
									keyMaterial: keyMaterial,
									forceTransaction: true
								)
							}
							showingAddSheet = false
						} catch {
							errorMessage = error.localizedDescription
						}
					}
				}
				.environmentObject(store)
			}
			.sheet(item: $editingHost) { host in
				HostFormView(mode: .edit(host)) { updated, secret, keyMaterial in
					Task { @MainActor in
						do {
							guard let current = store.hosts.first(where: {
								$0.id == updated.id
							}) else {
								editingHost = nil
								return
							}
							let identityIsConfirmed =
								updated.credentialIdentity?.migrationState
									== .confirmed
							if !identityIsConfirmed {
								let route = HostCredentialEditRouting.route(
									initial: host.credential,
									current: current.credential,
									updated: updated.credential,
									hasSecret: secret != nil,
									hasKeyMaterial: keyMaterial != nil
								)
								switch route {
								case .preserveCurrent:
									break
								case let .transact(forceSourceCommit):
									try await applyCredentialChange(
										hostId: updated.id,
										credential: updated.credential,
										secret: secret,
										keyMaterial: keyMaterial,
										forceTransaction: forceSourceCommit
									)
								}
							}
							if let committed = store.hosts.first(where: {
								$0.id == updated.id
							}) {
								var metadataUpdate = updated
								metadataUpdate.credential = committed.credential
								metadataUpdate.credentialMaterialDirty =
									committed.credentialMaterialDirty
								if identityIsConfirmed {
									try await store
										.confirmCredentialIdentityMigration(
											metadataUpdate
										)
								} else {
									try await store.updateHost(metadataUpdate)
								}
							}
							editingHost = nil
						} catch {
							errorMessage = error.localizedDescription
						}
					}
				}
				.environmentObject(store)
			}
			.onReceive(NotificationCenter.default.publisher(for: .catermEditHostRequested)) { note in
				guard WindowCommandScope.shouldHandle(note, in: hostWindow) else {
					return
				}
				guard let hostId = note.userInfo?[CatermEditHostRequestedKeys.hostId] as? UUID,
				      let host = store.hosts.first(where: { $0.id == hostId }) else {
					return
				}
				editingHost = host
			}
			.sheet(item: $pendingCredentialHost) { host in
				CredentialSetupView(host: host) { cred, secret, keyMaterial in
					if let keyMaterial {
						try await HostKeyProvisioner.provision(
							material: keyMaterial,
							hasPassphrase: credHasPassphrase(cred),
							passphrase: secret,
							hostId: host.id,
							sessionStore: store
						)
					} else {
						try await store.setHostCredentialMaterial(
							secrets: makeSecrets(for: cred, secret: secret),
							credentialSource: cred,
							for: host.id
						)
					}
					// Write succeeded — dismiss and re-enter connect with the
					// refreshed host (now needsCredentialSetup == false).
					if let refreshed = store.hosts.first(where: { $0.id == host.id }) {
						await MainActor.run {
							pendingCredentialHost = nil
							connect(refreshed)
						}
					}
				} onCancel: {
					pendingCredentialHost = nil
				}
			}
			.alert(
				"Error",
				isPresented: Binding(
					get: { errorMessage != nil },
					set: { if !$0 { errorMessage = nil } }
				),
				presenting: errorMessage
			) { _ in
				Button("OK") { errorMessage = nil }
			} message: { msg in
				Text(msg)
			}
			.alert(
				"Delete \(pendingFanoutDelete?.host.name ?? "")?",
				isPresented: Binding(
					get: { pendingFanoutDelete != nil },
					set: { if !$0 { pendingFanoutDelete = nil } }
				),
				presenting: pendingFanoutDelete
			) { pending in
				Button("Delete anyway", role: .destructive) {
					Task { @MainActor in
						do { try await store.deleteHost(id: pending.host.id) }
						catch { errorMessage = error.localizedDescription }
					}
				}
				Button("Cancel", role: .cancel) { }
			} message: { pending in
				Text("\(pending.host.name) is used by \(pending.dependents.count) host(s) as their jump host. Deleting will leave their chain references dangling.")
			}
			.onReceive(NotificationCenter.default.publisher(for: .catermAddHost)) { note in
				guard WindowCommandScope.shouldHandle(note, in: hostWindow) else {
					return
				}
				showingAddSheet = true
			}
			#if DEBUG
			.onReceive(NotificationCenter.default.publisher(for: .catermDebugOpenFirstHost)) { note in
				guard WindowCommandScope.shouldHandle(note, in: hostWindow) else {
					return
				}
				Task { @MainActor in
					if let target = await debugPickConnectTarget(in: store) {
						connect(target)
					}
				}
			}
			#endif

			Divider()
			Button {
				openWindow(id: HostManagerWindow.id)
			} label: {
				HStack(spacing: 8) {
					Image(systemName: "folder")
					Text("Manage Hosts")
					Spacer()
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 12)
				.padding(.vertical, 7)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityHint("Organizes hosts with groups and tags")
			Button {
				openWindow(id: SessionHistoryWindow.id)
			} label: {
				HStack(spacing: 8) {
					Image(systemName: "clock.arrow.circlepath")
					Text("Connection History")
					Spacer()
					Text("⇧⌘Y")
						.foregroundStyle(.tertiary)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 12)
				.padding(.vertical, 7)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityHint("Opens locally stored connection metadata")
			Button {
				openWindow(id: PortForwardWorkspaceWindow.id)
			} label: {
				HStack(spacing: 8) {
					Image(systemName: "arrow.left.arrow.right")
					Text("Port Forwarding")
					Spacer()
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 12)
				.padding(.vertical, 7)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityHint("Opens forwarding rules for saved hosts")
			Button {
				openWindow(id: SFTPTaskWindow.id)
			} label: {
				HStack(spacing: 8) {
					Image(systemName: "arrow.left.arrow.right.square")
					Text("File Transfer")
					Spacer()
					Text("⌥⌘F")
						.foregroundStyle(.tertiary)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 12)
				.padding(.vertical, 7)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityHint("Opens the dual-pane local and remote file workspace")
			Button {
				openWindow(id: KnownHostsWindow.id)
			} label: {
				HStack(spacing: 8) {
					Image(systemName: "checkmark.shield")
					Text("Known Hosts")
					Spacer()
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, 12)
				.padding(.vertical, 7)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityHint("Audits trusted SSH host keys")
			Divider()
			SyncStatusRow()
		}
		.background(WindowAccessor(window: $hostWindow))
	}

	/// Build a `HostSecrets` payload from the optional plain-text secret
	/// returned by the host form / credential setup view. Returns an empty
	/// `HostSecrets` for credential kinds that have no secret material
	/// (.agent, keyFile without passphrase) or when the user left the field
	/// blank — `setHostCredentialMaterial` treats an empty payload as
	/// "credential source change only, no Keychain write".
	private func makeSecrets(for cred: CredentialSource, secret: String?) -> HostSecrets {
		guard let secret, !secret.isEmpty else {
			return HostSecrets()
		}
		switch cred {
		case .password:
			return HostSecrets(password: Data(secret.utf8))
		case .keyFile(_, hasPassphrase: true):
			return HostSecrets(passphrase: Data(secret.utf8))
		default:
			return HostSecrets()
		}
	}

	/// Route a form submission's credential outcome. New key material is
	/// imported into managed storage (ADR 0003) via the Plan C entry point;
	/// otherwise commit a source/secret transaction. `forceTransaction`
	/// establishes credential state for a new host or a source-only edit even
	/// when the user has not supplied a new secret.
	private func applyCredentialChange(
		hostId: UUID, credential: CredentialSource,
		secret: String?, keyMaterial: PendingKeyMaterial?,
		forceTransaction: Bool
	) async throws {
		if let keyMaterial {
			try await HostKeyProvisioner.provision(
				material: keyMaterial,
				hasPassphrase: credHasPassphrase(credential),
				passphrase: secret,
				hostId: hostId,
				sessionStore: store
			)
			return
		}
		guard forceTransaction || secret != nil else { return }
		try await store.setHostCredentialMaterial(
			secrets: makeSecrets(for: credential, secret: secret),
			credentialSource: credential,
			for: hostId
		)
	}

	private func credHasPassphrase(_ cred: CredentialSource) -> Bool {
		if case .keyFile(_, hasPassphrase: true) = cred { return true }
		return false
	}

	private func connect(_ host: SSHHost) {
		Task { @MainActor in
			guard let current = store.hosts.first(where: { $0.id == host.id }) else {
				return
			}
			switch await resolveConnectIntent(for: current, in: store) {
			case .promptCredentials:
				pendingCredentialHost = current
			case .openTab:
				do {
					let workspace = try workspaceCoordinator.openSavedHost(
						current,
						installTerminfo: preferences.installTerminfoEnabled
					)
					onOpenWorkspace(workspace)
				} catch {
					errorMessage = error.localizedDescription
				}
			}
		}
	}

	private func submitSearch(
		visibleHosts: [SSHHost],
		quickDestination: QuickConnectDestination?
	) {
		let selected = selectedHostId.flatMap { selectedHostId in
			visibleHosts.first { $0.id == selectedHostId }
		}
		if let host = selected ?? visibleHosts.first {
			connect(host)
		} else if let quickDestination {
			connectOnce(quickDestination)
		}
	}

	private func connectOnce(_ destination: QuickConnectDestination) {
		do {
			let workspace = try workspaceCoordinator.openOneTimeHost(
				destination.makeHost(),
				installTerminfo: preferences.installTerminfoEnabled
			)
			onOpenWorkspace(workspace)
		} catch {
			errorMessage = error.localizedDescription
		}
	}

	private func deleteHost(_ host: SSHHost) {
		let dependents = store.hosts.filter {
			$0.id != host.id &&
			($0.jumpHostId == host.id || (host.serverId != nil && $0.jumpHostServerId == host.serverId))
		}
		if dependents.isEmpty {
			Task { @MainActor in
				do { try await store.deleteHost(id: host.id) }
				catch { errorMessage = error.localizedDescription }
			}
			return
		}
		pendingFanoutDelete = PendingFanoutDelete(host: host, dependents: dependents)
	}
}

private struct QuickConnectRow: View {
	let destination: QuickConnectDestination
	let onConnect: () -> Void

	var body: some View {
		Button(action: onConnect) {
			HStack(spacing: 8) {
				Image(systemName: "bolt.horizontal.circle")
					.foregroundStyle(.secondary)
					.frame(width: 20)
				VStack(alignment: .leading, spacing: 2) {
					Text("Connect Once")
						.font(.headline)
					Text(destination.displayAddress)
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.contentShape(Rectangle())
			.padding(.vertical, 2)
		}
		.buttonStyle(.plain)
		.help("Connect without saving. OpenSSH will request authentication in the terminal.")
		.accessibilityLabel("Connect once to \(destination.displayAddress)")
		.accessibilityHint("Does not save this host")
	}
}

/// SwiftUI's `List(selection:)` swallows row double-tap gestures on macOS.
/// Install the native AppKit double-action on the backing table instead.
struct HostListDoubleClickConnector: NSViewRepresentable {
	let hosts: [SSHHost]
	let onDoubleClick: (SSHHost) -> Void

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	func makeNSView(context: Context) -> InstallerView {
		let view = InstallerView()
		context.coordinator.update(hosts: hosts, onDoubleClick: onDoubleClick)
		context.coordinator.scheduleInstall(from: view)
		return view
	}

	func updateNSView(_ nsView: InstallerView, context: Context) {
		context.coordinator.update(hosts: hosts, onDoubleClick: onDoubleClick)
		context.coordinator.scheduleInstall(from: nsView)
	}

	static func dismantleNSView(_ nsView: InstallerView, coordinator: Coordinator) {
		coordinator.restorePreviousDoubleAction()
	}

	final class InstallerView: NSView {
		override func hitTest(_ point: NSPoint) -> NSView? {
			nil
		}
	}

	@MainActor
	final class Coordinator: NSObject {
		static let installedAction = #selector(forwardSingleAction(_:))
		static let installedDoubleAction = #selector(openClickedRow(_:))

		private var hosts: [SSHHost] = []
		private var onDoubleClick: ((SSHHost) -> Void)?
		private weak var tableView: NSTableView?
		private weak var previousTarget: AnyObject?
		private var previousAction: Selector?
		private var previousDoubleAction: Selector?

		func update(hosts: [SSHHost], onDoubleClick: @escaping (SSHHost) -> Void) {
			self.hosts = hosts
			self.onDoubleClick = onDoubleClick
		}

		func scheduleInstall(from view: NSView) {
			DispatchQueue.main.async { [weak self, weak view] in
				guard let self, let view else { return }
				self.install(from: view)
			}
		}

		func restorePreviousDoubleAction() {
			guard let tableView else { return }
			tableView.target = previousTarget
			tableView.action = previousAction
			tableView.doubleAction = previousDoubleAction
			self.tableView = nil
			previousTarget = nil
			previousAction = nil
			previousDoubleAction = nil
		}

		@objc func forwardSingleAction(_ sender: NSTableView) {
			guard let previousAction else { return }
			NSApplication.shared.sendAction(
				previousAction,
				to: previousTarget,
				from: sender
			)
		}

		@objc func openClickedRow(_ sender: NSTableView) {
			let row = sender.clickedRow
			guard hosts.indices.contains(row) else { return }
			onDoubleClick?(hosts[row])
		}

		// SwiftUI can restore its table action between representable updates
		// while leaving this coordinator installed as the target.
		@objc func onAction(_ sender: NSTableView) {
			if NSApp.currentEvent?.clickCount == 2 {
				openClickedRow(sender)
			} else {
				forwardSingleAction(sender)
			}
		}

		func install(on tableView: NSTableView) {
			if tableView !== self.tableView {
				restorePreviousDoubleAction()
				previousTarget = tableView.target as AnyObject?
				previousAction = tableView.action
				previousDoubleAction = tableView.doubleAction
				self.tableView = tableView
			}
			tableView.target = self
			tableView.action = Self.installedAction
			tableView.doubleAction = Self.installedDoubleAction
		}

		private func install(from view: NSView) {
			guard !hosts.isEmpty,
			      let tableView = findHostTableView(from: view)
			else { return }
			install(on: tableView)
		}

		private func findHostTableView(from view: NSView) -> NSTableView? {
			guard let contentView = view.window?.contentView else { return nil }
			let tables = contentView.descendants(of: NSTableView.self)
			let leftmost: ([NSTableView]) -> NSTableView? = { candidates in
				candidates.min { lhs, rhs in
					lhs.convert(lhs.bounds, to: nil).minX < rhs.convert(rhs.bounds, to: nil).minX
				}
			}
			// Primary signal: the sidebar table has exactly `hosts.count`
			// rows. If several tables tie (e.g. a same-length snippet
			// list), the sidebar is the leftmost. If NONE match — e.g.
			// during a List diff where the row count momentarily lags
			// `hosts` — fall back to the leftmost table rather than
			// missing the install entirely (a later updateNSView retries
			// anyway, but this avoids a transient dead double-click).
			let rowMatched = tables.filter { $0.numberOfRows == hosts.count }
			return leftmost(rowMatched) ?? leftmost(tables)
		}
	}
}

private struct HostSearchField: NSViewRepresentable {
	@Binding var text: String
	let onSubmit: () -> Void

	func makeCoordinator() -> Coordinator {
		Coordinator(parent: self)
	}

	func makeNSView(context: Context) -> NSSearchField {
		let field = NSSearchField()
		field.placeholderString = "Search hosts or ssh user@host"
		field.sendsWholeSearchString = true
		field.target = context.coordinator
		field.action = #selector(Coordinator.submit(_:))
		field.delegate = context.coordinator
		field.identifier = NSUserInterfaceItemIdentifier("hostSearchField")
		field.setAccessibilityLabel("Search hosts or connect once")
		return field
	}

	func updateNSView(_ field: NSSearchField, context: Context) {
		context.coordinator.parent = self
		if field.stringValue != text {
			field.stringValue = text
		}
		field.isEnabled = context.environment.isEnabled
	}

	final class Coordinator: NSObject, NSSearchFieldDelegate {
		var parent: HostSearchField

		init(parent: HostSearchField) {
			self.parent = parent
		}

		func controlTextDidChange(_ notification: Notification) {
			guard let field = notification.object as? NSSearchField else { return }
			parent.text = field.stringValue
		}

		@objc func submit(_ field: NSSearchField) {
			parent.text = field.stringValue
			parent.onSubmit()
		}
	}
}

private extension NSView {
	func descendants<T: NSView>(of type: T.Type) -> [T] {
		var matches: [T] = []
		if let match = self as? T {
			matches.append(match)
		}
		for subview in subviews {
			matches.append(contentsOf: subview.descendants(of: type))
		}
		return matches
	}
}

struct HostRow: View {
	@EnvironmentObject var store: SessionStore
	let host: SSHHost
	let chainResolution: ChainResolution
	@State private var needsCredentialSetup = false

	var body: some View {
		// Truncation strategy: three rounds of pure-SwiftUI defensive layout
		// (3a8f66d, b5ed2e8, e9fa0a6) — frame(maxWidth: .infinity), minWidth: 0,
		// fixedSize, clipped, layoutPriority — failed to make `.tail`
		// truncation work inside a NavigationSplitView sidebar's List row on
		// macOS 14. The user kept seeing trailing characters with the leading
		// portion clipped (e.g. "27:22" instead of "root@…").
		//
		// Replaced the SwiftUI Text + truncationMode(.tail) pattern with an
		// NSTextField bridge (TruncatingLabel) that uses the AppKit-native
		// single-line truncating cell (usesSingleLineMode = true,
		// lineBreakMode = .byTruncatingTail, lowered horizontal compression
		// resistance). This has worked reliably on macOS for 15+ years.
		HStack(spacing: 8) {
			Image(systemName: hostIconName(for: host))
				.foregroundColor(.secondary)
				.frame(width: 20)
				.layoutPriority(1)
			VStack(alignment: .leading, spacing: 2) {
				TruncatingLabel(
					text: host.name,
					font: NSFont.preferredFont(forTextStyle: .headline),
					color: .labelColor
				)
				TruncatingLabel(
					text: "\(host.username)@\(host.hostname):\(host.port)",
					font: NSFont.preferredFont(forTextStyle: .caption1),
					color: .secondaryLabelColor
				)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			if host.jumpHostId != nil || host.jumpHostServerId != nil {
				Image(systemName: "arrow.triangle.branch")
					.font(.caption2)
					.foregroundStyle(.secondary)
					.help(chainTooltip)
					.layoutPriority(1)
			}
			if needsCredentialSetup {
				Image(systemName: "lock")
					.foregroundColor(.orange)
					.help("Credentials not configured on this device")
					.layoutPriority(1)
			} else if host.serverId != nil {
				Image(systemName: "icloud")
					.foregroundColor(.secondary)
					.help("Synced from server")
					.layoutPriority(1)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.vertical, 2)
		.task(id: CredentialAvailabilityProbe(
			hostId: host.id,
			source: host.credential,
			revision: store.credentialAvailabilityRevision
		)) {
			let required = await store.needsCredentialSetup(
				host,
				interaction: .nonInteractive
			)
			guard !Task.isCancelled else { return }
			needsCredentialSetup = required
		}
	}

	private var chainTooltip: String {
		var names = chainResolution.ancestors.map(\.name)
		switch chainResolution.diagnostic {
		case .missing:
			names.append("(deleted)")
		case .cycle:
			names.append("(cycle)")
		case .none:
			break
		}
		return "via \(names.joined(separator: " → "))"
	}
}

private struct CredentialAvailabilityProbe: Equatable {
	let hostId: UUID
	let source: CredentialSource
	let revision: UInt64
}
