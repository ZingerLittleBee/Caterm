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
	let broadcastRecipientMarkers: [PaneID: String]

	init(
		workspace: Binding<Workspace>,
		restorationMessage: String?,
		broadcastRecipientMarkers: [PaneID: String] = [:]
	) {
		_workspace = workspace
		self.restorationMessage = restorationMessage
		self.broadcastRecipientMarkers = broadcastRecipientMarkers
	}

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
				case .host(let hostReference):
					if case .saved(let hostID) = hostReference,
					   !store.hosts.contains(where: { $0.id == hostID }) {
						WorkspaceMissingHostView(
							paneID: pane.id,
							workspace: $workspace,
							onActivate: activate
						)
					} else if let sessionID = workspaceCoordinator.sessionID(
						for: pane.id,
						in: workspace
					) {
						TerminalContainerView(
							tabId: sessionID,
							isFocused: isActive,
							onFocus: { activate(pane.id) },
							onClosePane: {
								activate(pane.id)
								WorkspaceCommandDispatcher.post(.closePane)
							}
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
			.overlay(alignment: .topLeading) {
				if let marker = broadcastRecipientMarkers[pane.id] {
					Label(marker, systemImage: "antenna.radiowaves.left.and.right")
						.font(.caption2.weight(.semibold))
						.foregroundStyle(.black)
						.padding(.horizontal, 7)
						.padding(.vertical, 4)
						.background(Color.orange, in: Capsule())
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
		.accessibilityValue(accessibilityValue(for: pane.id, isActive: isActive))
	}

	private func accessibilityValue(for paneID: PaneID, isActive: Bool) -> String {
		let focus = isActive ? "Active Pane" : "Inactive Pane"
		guard let marker = broadcastRecipientMarkers[paneID] else { return focus }
		return "\(focus), \(marker)"
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
	var replacesExistingHost = false
	var onConnected: () -> Void = {}
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
			if replacesExistingHost {
				workspace = try workspaceCoordinator.replaceSavedHost(
					host,
					in: paneID,
					workspace: workspace,
					installTerminfo: preferences.installTerminfoEnabled
				)
			} else {
				workspace = try workspaceCoordinator.connectSavedHost(
					host,
					to: paneID,
					in: workspace,
					installTerminfo: preferences.installTerminfoEnabled
				)
			}
			onConnected()
		} catch {
			errorMessage = error.localizedDescription
		}
	}
}

private struct WorkspaceMissingHostView: View {
	@EnvironmentObject private var store: SessionStore
	@EnvironmentObject private var preferences: SyncPreferences
	@EnvironmentObject private var workspaceCoordinator: WorkspaceCoordinator
	let paneID: PaneID
	@Binding var workspace: Workspace
	let onActivate: (PaneID) -> Void

	@State private var showingReplacement = false
	@State private var showingCreateHost = false
	@State private var errorMessage: String?
	@StateObject private var recoverySubmission = SingleFlightSubmission()

	var body: some View {
		VStack(spacing: 14) {
			Image(systemName: "questionmark.square.dashed")
				.font(.system(size: 36))
				.foregroundStyle(.secondary)
			Text("Host Unavailable")
				.font(.title3.weight(.semibold))
			Text("The saved Host for this Pane no longer exists. Caterm will not substitute another Host.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 420)
			HStack(spacing: 10) {
				Button("Replace…") {
					onActivate(paneID)
					showingReplacement = true
				}
				.buttonStyle(.borderedProminent)
				Button("Create Host…") {
					onActivate(paneID)
					showingCreateHost = true
				}
				Button("Remove Pane", role: .destructive) {
					onActivate(paneID)
					WorkspaceCommandDispatcher.post(.closePane)
				}
			}
		}
		.padding(24)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color(NSColor.windowBackgroundColor))
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Missing Host Pane")
		.accessibilityValue("Saved Host reference is unavailable")
		.sheet(isPresented: $showingReplacement) {
			VStack(spacing: 0) {
				WorkspaceHostPickerView(
					paneID: paneID,
					workspace: $workspace,
					onActivate: onActivate,
					replacesExistingHost: true,
					onConnected: { showingReplacement = false }
				)
				Divider()
				HStack {
					Spacer()
					Button("Cancel") { showingReplacement = false }
				}
				.padding(14)
			}
			.frame(width: 560, height: 560)
		}
		.sheet(isPresented: $showingCreateHost) {
			HostFormView(
				mode: .add,
				isSubmitting: recoverySubmission.isSubmitting
			) { host, secret, keyMaterial in
				recoverySubmission.submit {
					await createAndConnect(host, secret: secret, keyMaterial: keyMaterial)
				}
			}
			.environmentObject(store)
		}
		.onDisappear { recoverySubmission.cancel() }
		.alert(
			"Host Recovery Failed",
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

	@MainActor
	private func createAndConnect(
		_ host: SSHHost,
		secret: String?,
		keyMaterial: PendingKeyMaterial?
	) async {
		do {
			let transaction = WorkspaceMissingHostRecoveryTransaction(
				dependencies: .init(
					addHost: { try store.addHost($0) },
					commitCredential: { savedHost, secret, keyMaterial in
						if let keyMaterial {
							try await HostKeyProvisioner.provision(
								material: keyMaterial,
								hasPassphrase: savedHost.credential.hasPassphrase,
								passphrase: secret,
								hostId: savedHost.id,
								sessionStore: store
							)
						} else {
							try await store.setHostCredentialMaterial(
								secrets: HostSecrets(
									credential: savedHost.credential,
									secret: secret
								),
								credentialSource: savedHost.credential,
								for: savedHost.id
							)
						}
					},
					replacePane: { savedHost, paneID, workspace in
						try workspaceCoordinator.replaceSavedHost(
							savedHost,
							in: paneID,
							workspace: workspace,
							installTerminfo: preferences.installTerminfoEnabled
						)
					},
					rollbackHost: { hostID in
						try await store.deleteHost(id: hostID)
					}
				)
			)
			workspace = try await transaction.run(
				host: host,
				secret: secret,
				keyMaterial: keyMaterial,
				paneID: paneID,
				workspace: workspace
			)
			showingCreateHost = false
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
