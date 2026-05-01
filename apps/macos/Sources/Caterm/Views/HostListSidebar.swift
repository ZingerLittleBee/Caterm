import HostSyncStore
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
	let onOpenTab: (UUID) -> Void
	@State var selectedHostId: UUID?
	@State var showingAddSheet = false
	@State var editingHost: SSHHost?
	@State var errorMessage: String?
	@State var pendingCredentialHost: SSHHost?

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
								do { try store.deleteHost(id: host.id) }
								catch { errorMessage = error.localizedDescription }
							}
						}
						.onTapGesture(count: 2) { connect(host) }
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
						Text("Click + or press ⌘T to add one")
							.font(.caption)
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
					}
					.help("Add a new host (⌘T)")
				}
			}
			.sheet(isPresented: $showingAddSheet) {
				HostFormView(mode: .add) { host, secret in
					do {
						try store.addHost(host)
						if let secret { try persistSecret(host: host, secret: secret) }
						showingAddSheet = false
					} catch {
						errorMessage = error.localizedDescription
					}
				}
				.environmentObject(store)
			}
			.sheet(item: $editingHost) { host in
				HostFormView(mode: .edit(host)) { updated, secret in
					do {
						try store.updateHost(updated)
						if let secret { try persistSecret(host: updated, secret: secret) }
						editingHost = nil
					} catch {
						errorMessage = error.localizedDescription
					}
				}
				.environmentObject(store)
			}
			.sheet(item: $pendingCredentialHost) { host in
				CredentialSetupView(host: host) { cred, secret in
					// Order is intentional: Keychain (the operation that can fail
					// for legitimate reasons — locked Keychain, denied prompt) goes
					// FIRST. If it throws, no SessionStore mutation has happened
					// yet, so a subsequent Cancel is a clean no-op.
					if let secret, let kind = secretKind(for: cred) {
						try store.setHostSecret(secret, hostId: host.id, kind: kind)
					}
					try store.setCredentialOnly(cred, for: host.id)
					// Both writes succeeded — dismiss and re-enter connect with
					// the refreshed host (now needsCredentialSetup == false).
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
			.onReceive(NotificationCenter.default.publisher(for: .catermAddHost)) { _ in
				showingAddSheet = true
			}

			Divider()
			SyncStatusRow()
		}
	}

	private func persistSecret(host: SSHHost, secret: String) throws {
		switch host.credential {
		case .password:
			try store.setHostSecret(secret, hostId: host.id, kind: .password)
		case let .keyFile(_, hasPassphrase) where hasPassphrase:
			try store.setHostSecret(secret, hostId: host.id, kind: .keyPassphrase)
		default:
			break
		}
	}

	/// Map a CredentialSource to the keychain SecretKind that stores its
	/// secret material. Returns nil for cases that have no secret (.agent,
	/// keyFile without passphrase) — callers must guard on this.
	private func secretKind(for cred: CredentialSource) -> SessionStore.SecretKind? {
		switch cred {
		case .password: return .password
		case .keyFile(_, hasPassphrase: true): return .keyPassphrase
		default: return nil
		}
	}

	private func connect(_ host: SSHHost) {
		switch resolveConnectIntent(for: host, in: store) {
		case .promptCredentials:
			pendingCredentialHost = host
		case .openTab:
			let tabId = store.openTab(host: host)
			onOpenTab(tabId)
		}
	}
}

struct HostRow: View {
	@EnvironmentObject var store: SessionStore
	let host: SSHHost

	var body: some View {
		HStack {
			Image(systemName: iconName)
				.foregroundColor(.secondary)
				.frame(width: 20)
			VStack(alignment: .leading, spacing: 2) {
				Text(host.name).font(.headline)
				Text("\(host.username)@\(host.hostname):\(host.port)")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			Spacer()
			if store.needsCredentialSetup(host) {
				Image(systemName: "lock")
					.foregroundColor(.orange)
					.help("Credentials not configured on this device")
			} else if host.serverId != nil {
				Image(systemName: "icloud")
					.foregroundColor(.secondary)
					.help("Synced from server")
			}
		}
		.padding(.vertical, 2)
	}

	var iconName: String {
		switch host.credential {
		case .password: return "key.fill"
		case .keyFile: return "lock.shield.fill"
		case .agent: return "key.icloud.fill"
		}
	}
}
