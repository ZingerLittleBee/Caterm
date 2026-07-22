import AppKit
import HostKeyProvisioning
import HostSyncStore
import SessionStore
import SettingsStore
import SSHCommandBuilder
import SwiftUI
import TerminalEngine
import WorkspaceCore

struct WorkspacePaneTreeView: View {
	@EnvironmentObject private var store: SessionStore
	@EnvironmentObject private var settingsStore: SettingsStore
	@EnvironmentObject private var surfaceRegistry: SurfaceRegistry
	@EnvironmentObject private var preferences: SyncPreferences
	@EnvironmentObject private var workspaceCoordinator: WorkspaceCoordinator
	@Binding var workspace: Workspace
	let restorationMessage: String?

	var body: some View {
		let minimumWidth = WorkspaceTreeMinimumLength.length(
			for: workspace.topology,
			along: .horizontal,
			activePaneID: workspace.activePaneID,
			presentation: workspace.presentation
		)
		let minimumHeight = WorkspaceTreeMinimumLength.length(
			for: workspace.topology,
			along: .vertical,
			activePaneID: workspace.activePaneID,
			presentation: workspace.presentation
		)
		NativeWorkspaceTreeView(
			topology: workspace.topology,
			activePaneID: workspace.activePaneID,
			presentation: workspace.presentation,
			paneContent: { pane in
				environmentWrapped(AnyView(paneView(pane).id(pane.id)))
			},
			onRatioChange: { splitID, ratio in
				if let updated = try? workspace.updatingSplitRatio(
					ratio,
					splitID: splitID
				) {
					workspace = updated
				}
			}
		)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.frame(minWidth: minimumWidth, minHeight: minimumHeight)
	}

	private func paneView(_ pane: WorkspacePane) -> some View {
		let isActive = pane.id == workspace.activePaneID
		let isCompact = workspace.presentation == .focus && !isActive
		return ZStack {
			ZStack {
				switch pane.content {
				case .hostPicker:
					WorkspaceHostPickerView(
						paneID: pane.id,
						workspace: $workspace,
						onActivate: activate
					)
				case .host:
					if let sessionID = workspaceCoordinator.sessionID(
						for: pane.id,
						in: workspace
					) {
						TerminalContainerView(
							tabId: sessionID,
							isFocused: isActive,
							onFocus: { activate(pane.id) }
						)
					} else {
						missingSessionView
					}
				}
			}
			.contentShape(Rectangle())
			.onTapGesture { activate(pane.id) }
			.opacity(isCompact ? 0 : 1)
			.allowsHitTesting(!isCompact)
			.overlay {
				if workspace.topology.paneCount > 1 {
					RoundedRectangle(cornerRadius: 5, style: .continuous)
						.stroke(
							isActive ? Color.accentColor : Color.clear,
							lineWidth: 2
						)
						.padding(2)
						.allowsHitTesting(false)
				}
			}
			.overlay(alignment: .topTrailing) {
				if workspace.topology.paneCount > 1, isActive {
					Text("Active Pane")
						.font(.caption2.weight(.semibold))
						.foregroundStyle(.white)
						.padding(.horizontal, 7)
						.padding(.vertical, 3)
						.background(Color.accentColor, in: Capsule())
						.padding(8)
						.allowsHitTesting(false)
				}
			}
			if isCompact {
				WorkspacePaneRail(pane: pane, onActivate: activate)
			}
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Terminal Pane")
		.accessibilityValue(isActive ? "Active Pane" : "Inactive Pane")
	}

	private var missingSessionView: some View {
		ContentUnavailableView(
			"Host Unavailable",
			systemImage: "questionmark.square.dashed",
			description: Text(
				restorationMessage
					?? "The saved Host for this Pane is no longer available."
			)
		)
	}

	private func environmentWrapped(_ view: AnyView) -> AnyView {
		AnyView(
			view
				.environmentObject(store)
				.environmentObject(settingsStore)
				.environmentObject(surfaceRegistry)
				.environmentObject(preferences)
				.environmentObject(workspaceCoordinator)
		)
	}

	private func activate(_ paneID: PaneID) {
		guard paneID != workspace.activePaneID,
		      let updated = try? workspace.activatingPane(paneID) else {
			return
		}
		workspace = updated
	}
}

private struct WorkspacePaneRail: View {
	let pane: WorkspacePane
	let onActivate: (PaneID) -> Void

	var body: some View {
		Button {
			onActivate(pane.id)
		} label: {
			VStack(spacing: 5) {
				Image(systemName: pane.host == nil ? "plus" : "terminal")
				Text("Pane")
					.font(.caption2.weight(.medium))
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.buttonStyle(.plain)
		.help(pane.host?.displayName ?? "Focus Pane")
		.accessibilityLabel("Focus Pane")
		.background(.regularMaterial)
		.overlay {
			Rectangle()
				.stroke(Color(NSColor.separatorColor), lineWidth: 1)
				.allowsHitTesting(false)
		}
	}
}

private struct WorkspaceHostPickerView: View {
	@EnvironmentObject private var store: SessionStore
	@EnvironmentObject private var preferences: SyncPreferences
	@EnvironmentObject private var workspaceCoordinator: WorkspaceCoordinator
	let paneID: PaneID
	@Binding var workspace: Workspace
	let onActivate: (PaneID) -> Void
	@State private var query = ""
	@State private var pendingCredentialHost: SSHHost?
	@State private var errorMessage: String?

	private var visibleHosts: [SSHHost] {
		HostSearch.filter(store.hosts, query: query)
	}

	private func destination(for host: SSHHost) -> String {
		"\(host.username)@\(host.hostname):\(host.port)"
	}

	var body: some View {
		VStack(spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				Text("Choose a Host")
					.font(.title3.weight(.semibold))
				Text("The new Pane keeps its own SSH session.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			TextField("Search Hosts", text: $query)
				.textFieldStyle(.roundedBorder)
				.accessibilityLabel("Search Hosts for Pane")

			if visibleHosts.isEmpty {
				ContentUnavailableView(
					query.isEmpty ? "No Hosts" : "No Matching Hosts",
					systemImage: "rectangle.connected.to.line.below",
					description: Text(
						query.isEmpty
							? "Add a Host from the sidebar, then choose it here."
							: "Try a different search."
					)
				)
				.frame(maxHeight: .infinity)
			} else {
				ScrollView {
					LazyVStack(spacing: 4) {
						ForEach(visibleHosts) { host in
							Button {
								select(host)
							} label: {
								HStack(spacing: 10) {
									Image(systemName: "terminal")
										.foregroundStyle(.secondary)
									VStack(alignment: .leading, spacing: 2) {
										Text(host.name)
											.fontWeight(.medium)
										Text(destination(for: host))
											.font(.caption.monospaced())
											.foregroundStyle(.secondary)
									}
									Spacer()
									Image(systemName: "arrow.right.circle.fill")
										.foregroundStyle(.tint)
								}
								.padding(.horizontal, 10)
								.padding(.vertical, 8)
								.contentShape(Rectangle())
							}
							.buttonStyle(.plain)
							.accessibilityLabel("Connect \(host.name) in Pane")
						}
					}
				}
				.background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
			}
		}
		.padding(20)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color(NSColor.windowBackgroundColor))
		.onTapGesture { onActivate(paneID) }
		.sheet(item: $pendingCredentialHost) { host in
			CredentialSetupView(host: host) { credential, secret, keyMaterial in
				if let keyMaterial {
					try await HostKeyProvisioner.provision(
						material: keyMaterial,
						hasPassphrase: credential.hasPassphrase,
						passphrase: secret,
						hostId: host.id,
						sessionStore: store
					)
				} else {
					try await store.setHostCredentialMaterial(
						secrets: HostSecrets(credential: credential, secret: secret),
						credentialSource: credential,
						for: host.id
					)
				}
				guard let refreshed = store.hosts.first(where: { $0.id == host.id }) else {
					return
				}
				pendingCredentialHost = nil
				connect(refreshed)
			} onCancel: {
				pendingCredentialHost = nil
			}
		}
		.alert(
			"Pane Could Not Connect",
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
	}

	private func select(_ host: SSHHost) {
		onActivate(paneID)
		Task { @MainActor in
			guard let current = store.hosts.first(where: { $0.id == host.id }) else {
				return
			}
			switch await resolveConnectIntent(for: current, in: store) {
			case .promptCredentials:
				pendingCredentialHost = current
			case .openTab:
				connect(current)
			}
		}
	}

	private func connect(_ host: SSHHost) {
		do {
			workspace = try workspaceCoordinator.connectSavedHost(
				host,
				to: paneID,
				in: workspace,
				installTerminfo: preferences.installTerminfoEnabled
			)
		} catch {
			errorMessage = error.localizedDescription
		}
	}
}

private extension CredentialSource {
	var hasPassphrase: Bool {
		if case .keyFile(_, hasPassphrase: true) = self { return true }
		return false
	}
}

private extension HostSecrets {
	init(credential: CredentialSource, secret: String?) {
		guard let secret, !secret.isEmpty else {
			self.init()
			return
		}
		switch credential {
		case .password:
			self.init(password: Data(secret.utf8))
		case .keyFile(_, hasPassphrase: true):
			self.init(passphrase: Data(secret.utf8))
		default:
			self.init()
		}
	}
}
