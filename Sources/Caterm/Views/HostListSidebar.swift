import AppKit
import HostKeyProvisioning
import HostSyncStore
import ManagedKeyStore
import SessionStore
import SSHCommandBuilder
import SwiftUI

/// Sidebar listing the user's saved hosts. Provides:
/// - Add (toolbar + ⌘T notification)
/// - Edit (context menu)
/// - Delete (context menu)
/// - Connect (context menu / double-click) — delegates "open this new tab"
///   to the owning window via `onOpenTab`. A LandingView swaps its tab
///   identity in-place (so the empty Landing window becomes the new tab);
///   a MainWindow calls `openWindow(value:)` to spawn a sibling tab.
///   This avoids the previous behavior of always spawning a new window
///   and leaving the original Landing window around as a blank tab.
struct HostListSidebar: View {
	@EnvironmentObject var store: SessionStore
	@EnvironmentObject var syncStore: HostSyncStore       // NEW (v1.4)
	@EnvironmentObject var preferences: SyncPreferences   // NEW (v1.4)
	@EnvironmentObject var commandKeys: CommandKeyMonitor  // NEW (v1.7)
	@Environment(\.managedKeyStore) private var managedKeys
	let onOpenTab: (UUID) -> Void
	@State var selectedHostId: UUID?
	@State var showingAddSheet = false
	@State var editingHost: SSHHost?
	@State var errorMessage: String?
	@State var pendingCredentialHost: SSHHost?
	@State private var pendingFanoutDelete: PendingFanoutDelete?

	private struct PendingFanoutDelete: Identifiable {
		let host: SSHHost
		let dependents: [SSHHost]
		var id: UUID { host.id }
	}

	var body: some View {
		VStack(spacing: 0) {
			List(selection: $selectedHostId) {
				ForEach(store.hosts) { host in
					HostRow(host: host)
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
					HostListDoubleClickConnector(hosts: store.hosts) { host in
						connect(host)
					}
					.frame(width: proxy.size.width, height: proxy.size.height)
				}
			}
			.overlay {
				if store.hosts.isEmpty {
					VStack(spacing: 8) {
						Image(systemName: "server.rack")
							.font(.system(size: 32))
							.foregroundColor(.secondary)
						Text("No hosts yet")
							.foregroundColor(.secondary)
						Text("Click + or press ⌘⇧T to add a host")
							.font(.caption)
							.foregroundColor(.secondary)
						Text("⌘T opens a new tab • hold ⌘ to reveal shortcuts")
							.font(.caption2)
							.foregroundColor(.secondary)
					}
					.padding()
				}
			}
			.toolbar {
				ToolbarItem(placement: .primaryAction) {
					Button {
						showingAddSheet = true
					} label: {
						Image(systemName: "plus")
							.overlay(alignment: .bottomTrailing) {
								if commandKeys.isCommandHeld {
									ShortcutBadge(keys: "⇧⌘T")
										.offset(x: 10, y: 8)
								}
							}
					}
					.help("Add a new host (⇧⌘T)")
				}
			}
			.sheet(isPresented: $showingAddSheet) {
				HostFormView(mode: .add) { host, secret, keyMaterial in
					do {
						try store.addHost(host)
						try applyCredentialChange(
							hostId: host.id, credential: host.credential,
							secret: secret, keyMaterial: keyMaterial,
							forceSecretWrite: true
						)
						showingAddSheet = false
					} catch {
						errorMessage = error.localizedDescription
					}
				}
				.environmentObject(store)
			}
			.sheet(item: $editingHost) { host in
				HostFormView(mode: .edit(host)) { updated, secret, keyMaterial in
					do {
						try store.updateHost(updated)
						// Only route through the Plan C credential entry point
						// when the user supplied a new secret or new key
						// material. A pure metadata edit (rename / hostname /
						// port / username) must not flip
						// `credentialMaterialDirty` or fire the credential
						// changed notification.
						try applyCredentialChange(
							hostId: updated.id, credential: updated.credential,
							secret: secret, keyMaterial: keyMaterial,
							forceSecretWrite: false
						)
						editingHost = nil
					} catch {
						errorMessage = error.localizedDescription
					}
				}
				.environmentObject(store)
			}
			.onReceive(NotificationCenter.default.publisher(for: .catermEditHostRequested)) { note in
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
							sessionStore: store,
							managedKeys: managedKeys
						)
					} else {
						try store.setHostCredentialMaterial(
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
					do { try store.deleteHost(id: pending.host.id) }
					catch { errorMessage = error.localizedDescription }
				}
				Button("Cancel", role: .cancel) { }
			} message: { pending in
				Text("\(pending.host.name) is used by \(pending.dependents.count) host(s) as their jump host. Deleting will leave their chain references dangling.")
			}
			.onReceive(NotificationCenter.default.publisher(for: .catermAddHost)) { _ in
				showingAddSheet = true
			}
			#if DEBUG
			.onReceive(NotificationCenter.default.publisher(for: .catermDebugOpenFirstHost)) { _ in
				if let target = debugPickConnectTarget(in: store) {
					connect(target)
				}
			}
			#endif

			if commandKeys.isCommandHeld {
				ShortcutHintBar()
			}
			Divider()
			SyncStatusRow()
		}
		.animation(.easeOut(duration: 0.12), value: commandKeys.isCommandHeld)
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
	/// otherwise fall back to the direct secret write. `forceSecretWrite`
	/// distinguishes the add flow (always establish credential state, even
	/// with an empty secret) from the edit flow (only touch credential
	/// state when the user actually supplied something new).
	private func applyCredentialChange(
		hostId: UUID, credential: CredentialSource,
		secret: String?, keyMaterial: PendingKeyMaterial?,
		forceSecretWrite: Bool
	) throws {
		if let keyMaterial {
			// Managed-key write is an actor hop — provision asynchronously;
			// failures surface through the sidebar's error alert and the
			// host falls back to needsCredentialSetup on next connect.
			Task {
				do {
					try await HostKeyProvisioner.provision(
						material: keyMaterial,
						hasPassphrase: credHasPassphrase(credential),
						passphrase: secret,
						hostId: hostId,
						sessionStore: store,
						managedKeys: managedKeys
					)
				} catch {
					errorMessage = error.localizedDescription
				}
			}
			return
		}
		guard forceSecretWrite || secret != nil else { return }
		try store.setHostCredentialMaterial(
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
		switch resolveConnectIntent(for: host, in: store) {
		case .promptCredentials:
			pendingCredentialHost = host
		case .openTab:
			let tabId = store.openTab(host: host,
			                          installTerminfo: preferences.installTerminfoEnabled)
			onOpenTab(tabId)
		}
	}

	private func deleteHost(_ host: SSHHost) {
		let dependents = store.hosts.filter {
			$0.id != host.id &&
			($0.jumpHostId == host.id || (host.serverId != nil && $0.jumpHostServerId == host.serverId))
		}
		if dependents.isEmpty {
			do { try store.deleteHost(id: host.id) }
			catch { errorMessage = error.localizedDescription }
			return
		}
		pendingFanoutDelete = PendingFanoutDelete(host: host, dependents: dependents)
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
		static let installedDoubleAction = #selector(openClickedRow(_:))

		private var hosts: [SSHHost] = []
		private var onDoubleClick: ((SSHHost) -> Void)?
		private weak var tableView: NSTableView?
		private weak var previousTarget: AnyObject?
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
			tableView.doubleAction = previousDoubleAction
			self.tableView = nil
			previousTarget = nil
			previousDoubleAction = nil
		}

		@objc func openClickedRow(_ sender: NSTableView) {
			let row = sender.clickedRow
			guard hosts.indices.contains(row) else { return }
			onDoubleClick?(hosts[row])
		}

		func install(on tableView: NSTableView) {
			if tableView !== self.tableView {
				restorePreviousDoubleAction()
				previousTarget = tableView.target as AnyObject?
				previousDoubleAction = tableView.doubleAction
				self.tableView = tableView
			}
			tableView.target = self
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
					.help(chainTooltip(for: host))
					.layoutPriority(1)
			}
			if store.needsCredentialSetup(host) {
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
	}

	private func chainTooltip(for host: SSHHost) -> String {
		var names: [String] = []
		var cursor: SSHHost? = host
		var visited: Set<UUID> = []
		while let current = cursor {
			if let nextId = current.jumpHostId {
				if visited.contains(nextId) { names.append("(cycle)"); break }
				visited.insert(nextId)
				guard let parent = store.hosts.first(where: { $0.id == nextId }) else {
					names.append("(deleted)")
					break
				}
				names.append(parent.name)
				cursor = parent
				continue
			}
			if let nextSid = current.jumpHostServerId {
				guard let parent = store.hosts.first(where: { $0.serverId == nextSid }) else {
					names.append("(deleted)")
					break
				}
				names.append(parent.name)
				cursor = parent
				continue
			}
			break
		}
		return "via \(names.joined(separator: " → "))"
	}
}
