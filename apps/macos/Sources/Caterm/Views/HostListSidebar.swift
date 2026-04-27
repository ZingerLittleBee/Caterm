import SessionStore
import SSHCommandBuilder
import SwiftUI

/// Sidebar listing the user's saved hosts. Provides:
/// - Add (toolbar + ⌘T notification)
/// - Edit (context menu)
/// - Delete (context menu)
/// - Connect (context menu / double-click) — opens a new tab via OpenTabBridge
struct HostListSidebar: View {
	@EnvironmentObject var store: SessionStore
	@State var selectedHostId: UUID?
	@State var showingAddSheet = false
	@State var editingHost: SSHHost?
	@State var errorMessage: String?

	var body: some View {
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

	private func connect(_ host: SSHHost) {
		let tabId = store.openTab(host: host)
		NotificationCenter.default.post(
			name: .catermOpenTab, object: nil, userInfo: ["tabId": tabId]
		)
	}
}

struct HostRow: View {
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
