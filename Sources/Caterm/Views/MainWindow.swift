import AppKit
import FileTransferStore
import HostSyncStore
import SessionStore
import SFTPCommandBuilder
import SnippetStore
import SnippetSyncClient
import SSHCommandBuilder
import SwiftUI
import TerminalEngine
import WorkspaceBroadcast
import WorkspaceCore
import WorkspaceTemplateStore

enum MainWindowToolbarAction: CaseIterable {
	case snippets
	case files

	var systemImage: String {
		switch self {
		case .snippets: "text.cursor"
		case .files: "folder"
		}
	}

	var help: String {
		switch self {
		case .snippets: "Snippets (⌘⇧P)"
		case .files: "Toggle Files Drawer (⌘⇧F)"
		}
	}
}

enum MainWindowSnippetPalettePlacement {
	static let preferredSize = CGSize(width: 520, height: 380)

	static func frame(in container: CGSize) -> CGRect {
		let width = min(preferredSize.width, container.width)
		let height = min(preferredSize.height, container.height)
		return CGRect(
			x: (container.width - width) / 2,
			y: (container.height - height) / 2,
			width: width,
			height: height
		)
	}
}

/// Content of one native window tab. The window owns a durable Workspace
/// identity while `SessionStore` continues to own the one runtime SSH session.
/// A one-Pane Workspace deliberately renders the existing terminal UI without
/// pane headers or a custom tab strip.
struct MainWindow: View {
	@EnvironmentObject var store: SessionStore
	@EnvironmentObject var preferences: SyncPreferences
	@EnvironmentObject var fileTransferStore: FileTransferStore
	@EnvironmentObject var surfaceRegistry: SurfaceRegistry
	@EnvironmentObject var snippetStore: SnippetStore
	@EnvironmentObject var snippetSync: SnippetSyncStore
	@EnvironmentObject var workspaceCoordinator: WorkspaceCoordinator
	@EnvironmentObject var workspaceTemplateStore: WorkspaceTemplateStore
	@Environment(\.openWindow) private var openWindow
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@StateObject private var bannerState = SettingsBannerState()
	@StateObject private var broadcastSession = WorkspaceBroadcastSession()
	@State private var fileDrawerOpen = false
	@State private var drawerWidth: CGFloat = 320
	@State private var pendingUpload: PendingPaneUpload?
	@State private var showUploadSheet = false
	@State private var fileToolMessage: String?
	@State private var presentingPalette = false
	@State private var presentingEditor = false
	@State private var presentingManager = false
	@State private var presentingTemplateManager = false
	@State private var presentingTemplateName = false
	@State private var presentingBroadcastComposer = false
	@State private var reviewedBroadcastPlan: WorkspaceBroadcastPlan?
	@State private var broadcastMessage: String?
	@State private var hostWindow: NSWindow?
	@State private var remoteFsCache = RemoteFsCache()
	@State private var restorationStatus = WorkspaceRestorationStatus.pending
	@Binding var workspace: Workspace

	private static let drawerMinWidth: CGFloat = 240
	private static let drawerMaxWidth: CGFloat = 600

	private var activeSessionID: UUID? {
		workspaceCoordinator.sessionID(for: workspace)
	}

	private var broadcastCandidates: [WorkspaceBroadcastRecipient] {
		WorkspaceBroadcastResolver.candidates(
			in: workspace,
			coordinator: workspaceCoordinator,
			store: store,
			registry: surfaceRegistry
		)
	}

	private var broadcastRecipientMarkers: [PaneID: String] {
		Dictionary(uniqueKeysWithValues:
			broadcastSession.activePlan?.recipients.map { recipient in
				(recipient.paneID, "Broadcast Receiver · \(recipient.paneLabel)")
			} ?? []
		)
	}

	private var hasMissingWorkspaceHost: Bool {
		workspace.topology.panes.contains { pane in
			pane.host != nil
				&& workspaceCoordinator.sessionID(for: pane.id, in: workspace) == nil
		}
	}

	/// Host backing the active Pane's runtime session.
	private var activeHost: SSHHost? {
		guard let activeSessionID else { return nil }
		return store.tabs.first(where: { $0.id == activeSessionID })?.host
	}

	private var activeFileContext: ActivePaneFileContext {
		let sessionID = workspaceCoordinator.sessionID(for: workspace)
		let tab = sessionID.flatMap { sessionID in
			store.tabs.first(where: { $0.id == sessionID })
		}
		let savedHostExists: Bool
		if let hostReference = workspace.topology.pane(id: workspace.activePaneID)?.host,
		   case .saved(let hostID) = hostReference {
			savedHostExists = store.hosts.contains(where: { $0.id == hostID })
		} else {
			savedHostExists = false
		}
		return ActivePaneFileContextResolver.resolve(
			workspace: workspace,
			sessionID: sessionID,
			tab: tab,
			savedHostExists: savedHostExists
		)
	}

	private var activeFileHost: SSHHost? {
		guard case .ready(let target) = activeFileContext else { return nil }
		return store.tabs.first(where: { $0.id == target.sessionID })?.host
	}

	private var skippedForwardBannerText: String {
		let scoped = store.skippedForwardNotices.filter {
			$0.tabId == activeSessionID
		}
		guard !scoped.isEmpty else { return "" }
		let descs = scoped.map { n -> String in
			let bind: String
			if let addr = n.forward.bindAddress, !addr.isEmpty {
				bind = "\(addr):\(n.forward.bindPort)"
			} else {
				bind = String(n.forward.bindPort)
			}
			return "\(n.forward.kind.rawValue) \(bind) (\(n.reason.rawValue))"
		}
		return "Skipped optional port forward(s): " + descs.joined(separator: ", ")
	}

	/// The `RemoteFileSystem` for the active host, created once per
	/// `host.id` and reused across renders. The actor is cheap, but
	/// re-creating it on every `body` evaluation handed `FileDrawerView` a
	/// fresh actor identity on every unrelated `MainWindow` re-render
	/// (drawer drag, banner toggle, palette state); in-flight
	/// rename/delete/mkdir tasks then captured a now-orphaned instance.
	/// `RemoteFsCache` keeps a stable instance keyed by the exact active file target.
	private var activeRemoteFs: RemoteFileSystem? {
		guard case .ready(let target) = activeFileContext,
		      let host = activeFileHost else { return nil }
		return remoteFsCache.fileSystem(for: target) {
			let cm = ControlMasterManager.shared
			return RemoteFileSystem(
				host: host,
				controlPath: cm.socketPath(for: host.id),
				credentials: SFTPCredentials(
					knownHostsCaterm: URL(fileURLWithPath: store.knownHostsCaterm),
					knownHostsUser: URL(fileURLWithPath: store.knownHostsUser),
					strictHostKeyChecking: .acceptNew
				),
				liveness: cm
			)
		}
	}

	/// Returns the surface registered for this Workspace's session, used to dispatch
	/// snippet paste/run commands from the palette.
	private func resolveActiveSurface() -> (any SnippetDispatchTarget)? {
		guard let activeSessionID else { return nil }
		return surfaceRegistry.surface(for: activeSessionID)
	}

	var body: some View {
		VStack(spacing: 0) {
			if let plan = broadcastSession.activePlan {
				WorkspaceBroadcastBanner(
					plan: plan,
					isDelivering: broadcastSession.isDelivering,
					onReview: { reviewedBroadcastPlan = plan },
					onStop: stopBroadcast
				)
			}
			// Banners collapse to nothing when their state is empty, so for
			// the common case the layout is identical to the pre-banner
			// version. They sit above the split view so users see them
			// regardless of which sidebar/drawer is open.
			if !skippedForwardBannerText.isEmpty {
				Banner(
					text: skippedForwardBannerText,
					onDismiss: { store.clearSkippedForwardNotices(forTab: activeSessionID) }
				)
			}
			if !bannerState.diagnosticMessages.isEmpty {
				DiagnosticBanner(
					messages: bannerState.diagnosticMessages,
					onDismiss: bannerState.dismissDiagnostics
				)
			}
			if bannerState.showNewSurfaceBanner {
				Banner(
					text: "Some settings (scrollback / titlebar) apply to new sessions only.",
					onDismiss: bannerState.dismissNewSurface
				)
			}
			// NavigationSplitView fills the full window width; the drawer
			// is layered on top via ZStack rather than reserving layout
			// space. Earlier attempts that constrained NavigationSplitView
			// to (window − drawer) width either let NSSplitView's sidebar
			// animation push the drawer ~30–115pt right (HStack /
			// padding+overlay variants) or kept the drawer pinned but
			// shrank detail's title-bar area enough that the toolbar
			// briefly showed a `>>` overflow chevron during sidebar
			// expansion (.frame(width: navWidth) variant). With the
			// drawer as a ZStack overlay anchored to the outer
			// GeometryReader's trailing edge, NavigationSplitView's
			// outer frame never changes, so neither the drawer nor the
			// toolbar feels the sidebar animation. The drawer needs an
			// opaque background since it now sits over the detail
			// region's content.
			GeometryReader { geo in
				let drawerTotal: CGFloat = fileDrawerOpen
					? drawerWidth + 1 : 0
				ZStack(alignment: .topLeading) {
					NavigationSplitView {
						// Already a Workspace — connecting from this sidebar
						// should spawn a sibling tabbed window
						// rather than replacing this Workspace's session.
						HostListSidebar(onOpenWorkspace: { newWorkspace in
							openWindow(value: WorkspaceWindowState.workspace(newWorkspace))
						})
							.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
					} detail: {
						Group {
							if restorationStatus == .pending {
								workspaceRestorationPlaceholder
							} else {
								WorkspacePaneTreeView(
									workspace: $workspace,
									restorationMessage: restorationMessage,
									broadcastRecipientMarkers: broadcastRecipientMarkers
								)
								.padding(.trailing, drawerTotal)
							}
						}
						.frame(maxWidth: .infinity, maxHeight: .infinity)
						.frame(minWidth: 400, minHeight: 500)
					}

					if fileDrawerOpen {
						HStack(spacing: 0) {
							DrawerDragHandle(
								width: $drawerWidth,
								minWidth: Self.drawerMinWidth,
								maxWidth: Self.drawerMaxWidth
							)
							FileDrawerView(
								paneID: workspace.activePaneID,
								context: activeFileContext,
								host: activeFileHost,
								fs: activeRemoteFs,
								fileTransferStore: fileTransferStore,
								currentContext: { activeFileContext }
							)
							.frame(width: drawerWidth)
						}
						.frame(width: drawerTotal, height: geo.size.height)
						// Use a material rather than windowBackgroundColor so
						// the drawer's vibrancy matches the title bar's
						// NSVisualEffectView. With a flat fill there was a
						// visible seam at the title-bar bottom edge where the
						// drawer's flat color met the title bar's translucent
						// gray.
						.background(.regularMaterial)
						.offset(x: geo.size.width - drawerTotal, y: 0)
						.transition(.move(edge: .trailing))
					}

					if presentingPalette {
						Color.black.opacity(0.001)
							.contentShape(Rectangle())
							.onTapGesture { presentingPalette = false }
							.zIndex(9)

						let paletteFrame = MainWindowSnippetPalettePlacement.frame(in: geo.size)
						snippetPalette
							.frame(width: paletteFrame.width, height: paletteFrame.height)
							.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
							.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
							.overlay(
								RoundedRectangle(cornerRadius: 14, style: .continuous)
									.stroke(Color(NSColor.separatorColor), lineWidth: 1)
							)
							.shadow(color: .black.opacity(0.28), radius: 24, y: 12)
							.position(x: paletteFrame.midX, y: paletteFrame.midY)
							.zIndex(10)
					}
				}
				.animation(
					WorkspaceMotionPolicy.presentationAnimation(reduceMotion: reduceMotion),
					value: fileDrawerOpen
				)
			}
		}
		.frame(minWidth: 1000, minHeight: 600)
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button {
					handleWorkspaceCommand(.splitRight)
				} label: {
					Image(systemName: "rectangle.split.2x1")
				}
				.accessibilityLabel("Split Right")
				.help("Split the active Pane to the right (⌘D)")
			}
			ToolbarItem(placement: .primaryAction) {
				Button {
					presentingBroadcastComposer = true
				} label: {
					Image(systemName: "antenna.radiowaves.left.and.right")
				}
				.accessibilityLabel("Review Command Broadcast")
				.help("Review Command Broadcast")
				.disabled(broadcastSession.activePlan != nil)
			}
			ToolbarItem(placement: .primaryAction) {
				Menu {
					Button("Save Workspace as Template…") {
						presentingTemplateName = true
					}
					Divider()
					Button("Manage Workspace Templates…") {
						presentingTemplateManager = true
					}
				} label: {
					Image(systemName: "rectangle.stack")
				}
				.accessibilityLabel("Workspace Templates")
				.help("Workspace Templates")
			}
			ToolbarItemGroup(placement: .primaryAction) {
				ForEach(MainWindowToolbarAction.allCases, id: \.self) { action in
					Button {
						handlePrimaryToolbarAction(action)
					} label: {
						Image(systemName: action.systemImage)
					}
					.help(action.help)
				}
			}
		}
		.focusedSceneValue(
			\.workspaceCommandHandler,
			WorkspaceCommandHandler(perform: handleWorkspaceCommand)
		)
		.onReceive(NotificationCenter.default
			.publisher(for: .toggleFileDrawer)) { notification in
			guard WindowCommandScope.shouldHandle(notification, in: hostWindow) else {
				return
			}
			fileDrawerOpen.toggle()
		}
		.onReceive(NotificationCenter.default
			.publisher(for: .catermOptionDragUpload)) { note in
			guard WindowCommandScope.shouldHandle(note, in: hostWindow) else {
				return
			}
			guard let urls = note.userInfo?["urls"] as? [URL], !urls.isEmpty else { return }
			guard case .ready(let target) = activeFileContext else {
				if case .unavailable(let unavailable) = activeFileContext {
					fileToolMessage = unavailable.message
				}
				return
			}
			pendingUpload = PendingPaneUpload(urls: urls, target: target)
			showUploadSheet = true
		}
		.onReceive(NotificationCenter.default
			.publisher(for: .catermWorkspaceCommand)) { note in
			guard WindowCommandScope.shouldHandle(note, in: hostWindow),
			      let command = note.userInfo?[WorkspaceCommandNotificationKey.command]
				as? WorkspaceCommand else {
				return
			}
			handleWorkspaceCommand(command)
		}
		.onReceive(NotificationCenter.default
			.publisher(for: .catermSaveWorkspaceTemplate)) { note in
			guard WindowCommandScope.shouldHandle(note, in: hostWindow) else { return }
			presentingTemplateName = true
		}
		.onReceive(NotificationCenter.default
			.publisher(for: .catermManageWorkspaceTemplates)) { note in
			guard WindowCommandScope.shouldHandle(note, in: hostWindow) else { return }
			presentingTemplateManager = true
		}
		.sheet(isPresented: $showUploadSheet) {
			SimpleTextSheet(
				title: "Upload to remote directory",
				prompt: "Path",
				initialValue: "~",
				onSubmit: { remoteDir in
					showUploadSheet = false
					if let pendingUpload,
					   pendingUpload.canSubmit(in: activeFileContext),
					   let host = activeFileHost {
						_ = fileTransferStore.enqueueUpload(
							localPaths: pendingUpload.urls,
							remoteDir: remoteDir,
							host: host
						)
					} else if pendingUpload != nil {
						fileToolMessage = "The active Pane changed before the upload was confirmed. Start the upload again."
					}
					pendingUpload = nil
				},
				onCancel: {
					showUploadSheet = false
					pendingUpload = nil
				}
			)
		}
		.background(
			WorkspaceWindowLifecycleObserver(window: $hostWindow) {
				for pane in workspace.topology.panes {
					if let sessionID = workspaceCoordinator.sessionID(
						for: pane.id,
						in: workspace
					) {
						surfaceRegistry.unregister(sessionID)
					}
				}
				workspaceCoordinator.closeWorkspace(workspace.id)
			}
		)
		.alert(
			"Files Unavailable",
			isPresented: Binding(
				get: { fileToolMessage != nil },
				set: { if !$0 { fileToolMessage = nil } }
			),
			presenting: fileToolMessage
		) { _ in
			Button("OK") { fileToolMessage = nil }
		} message: { message in
			Text(message)
		}
		.modifier(SnippetCommandObserver(
			presentingPalette: $presentingPalette,
			presentingEditor: $presentingEditor,
			presentingManager: $presentingManager,
			isKeyWindow: { hostWindow?.isKeyWindow ?? false }
		))
		.sheet(isPresented: $presentingEditor) {
			SnippetEditorSheet(mode: .create)
				.environmentObject(snippetStore)
				.environmentObject(snippetSync)
		}
		.sheet(isPresented: $presentingManager) {
			SnippetManagerSheet()
				.environmentObject(snippetStore)
				.environmentObject(snippetSync)
		}
		.sheet(isPresented: $presentingTemplateName) {
			WorkspaceTemplateSaveSheet(workspace: workspace)
		}
		.sheet(isPresented: $presentingTemplateManager) {
			WorkspaceTemplateManagerSheet(
				currentWorkspace: workspace,
				onOpen: { newWorkspace in
					openWindow(value: WorkspaceWindowState.workspace(newWorkspace))
				}
			)
		}
		.task(id: workspace.id) {
			do {
				try workspaceCoordinator.ensureSessions(
					for: workspace,
					installTerminfo: preferences.installTerminfoEnabled
				)
				restorationStatus = hasMissingWorkspaceHost ? .missingHost : .ready
			} catch {
				restorationStatus = .failed(error.localizedDescription)
			}
		}
		.modifier(WorkspaceBroadcastWindowModifier(
			session: broadcastSession,
			workspace: $workspace,
			presentingComposer: $presentingBroadcastComposer,
			reviewedPlan: $reviewedBroadcastPlan,
			message: $broadcastMessage,
			candidates: broadcastCandidates,
			snippets: snippetStore.snippets,
			hostWindow: hostWindow,
			onReconcile: reconcileBroadcastEligibility,
			onDeliver: deliverBroadcast,
			onStop: stopBroadcast
		))
	}

	private var restorationMessage: String? {
		switch restorationStatus {
		case .pending, .ready:
			nil
		case .missingHost:
			"This Workspace is safe, but one of its saved Hosts is no longer available."
		case .failed(let message):
			message
		}
	}

	@ViewBuilder
	private var workspaceRestorationPlaceholder: some View {
		switch restorationStatus {
		case .pending, .ready:
			ProgressView("Restoring Workspace…")
		case .missingHost:
			ContentUnavailableView(
				"Host Unavailable",
				systemImage: "questionmark.square.dashed",
				description: Text("This Workspace is safe, but its saved Host is no longer available.")
			)
		case .failed(let message):
			ContentUnavailableView(
				"Workspace Could Not Open",
				systemImage: "exclamationmark.triangle",
				description: Text(message)
			)
		}
	}

	private func handlePrimaryToolbarAction(_ action: MainWindowToolbarAction) {
		switch action {
		case .snippets:
			presentingPalette = true
		case .files:
			fileDrawerOpen.toggle()
		}
	}

	private func handleWorkspaceCommand(_ command: WorkspaceCommand) {
		do {
			switch try command.applying(to: workspace) {
			case .update(let updated):
				workspace = updated
			case .close(let result):
				guard !result.shouldCloseWindow, let updated = result.workspace else {
					hostWindow?.performClose(nil)
					return
				}
				if let sessionID = workspaceCoordinator.sessionID(
					for: result.closedPaneID,
					in: workspace
				) {
					surfaceRegistry.unregister(sessionID)
				}
				workspaceCoordinator.closePane(
					result.closedPaneID,
					in: workspace.id
				)
				workspace = updated
			}
		} catch {
			restorationStatus = .failed(error.localizedDescription)
		}
	}

	private func reconcileBroadcastEligibility() {
		let result = broadcastSession.reconcileEligibility { recipient in
			WorkspaceBroadcastResolver.eligibility(
				of: recipient,
				in: workspace,
				coordinator: workspaceCoordinator,
				store: store,
				registry: surfaceRegistry
			)
		}
		switch result {
		case .unchanged:
			break
		case .disarmed:
			reviewedBroadcastPlan = nil
			broadcastMessage = "Fewer than two armed recipients remain connected. No command was sent."
		case .stoppingDelivery:
			reviewedBroadcastPlan = nil
		}
	}

	private func deliverBroadcast() {
		Task { @MainActor in
			await broadcastSession.deliver(
				eligibility: { recipient in
					WorkspaceBroadcastResolver.eligibility(
						of: recipient,
						in: workspace,
						coordinator: workspaceCoordinator,
						store: store,
						registry: surfaceRegistry
					)
				},
				send: { recipient, text in
					try WorkspaceBroadcastResolver.send(
						text,
						to: recipient,
						registry: surfaceRegistry
					)
				}
			)
		}
	}

	private func stopBroadcast() {
		broadcastSession.stop()
		reviewedBroadcastPlan = nil
	}

	private var snippetPalette: some View {
		SnippetPalette(
			store: snippetStore,
			sync: snippetSync,
			capturedSurface: resolveActiveSurface(),
			onClose: { presentingPalette = false },
			onCreate: { presentingPalette = false; presentingEditor = true }
		)
	}
}

private enum WorkspaceRestorationStatus: Equatable {
	case pending
	case ready
	case missingHost
	case failed(String)
}

/// Caches one `RemoteFileSystem` per active Pane/session/Host target so a stable instance
/// survives unrelated `MainWindow` re-renders. Reference type held via
/// `@State`, so SwiftUI keeps the same cache across the view's lifetime.
/// The cached instance is replaced whenever the active file target changes.
@MainActor
final class RemoteFsCache {
	private var cached: (target: ActivePaneFileTarget, fs: RemoteFileSystem)?

	func fileSystem(
		for target: ActivePaneFileTarget,
		make: () -> RemoteFileSystem
	) -> RemoteFileSystem {
		if let cached, cached.target == target { return cached.fs }
		let fs = make()
		cached = (target, fs)
		return fs
	}
}

struct PendingPaneUpload: Equatable {
	let urls: [URL]
	let target: ActivePaneFileTarget

	func canSubmit(in context: ActivePaneFileContext) -> Bool {
		context == .ready(target)
	}
}

/// 1pt visual divider with a 6pt-wide invisible hit area that drives
/// click-and-drag resizing of the SFTP file drawer. Replaces the divider that
/// HSplitView used to provide; the rest of the drawer geometry is plain
/// HStack so the layout reflows cleanly when the drawer toggles closed.
struct DrawerDragHandle: View {
	@Binding var width: CGFloat
	let minWidth: CGFloat
	let maxWidth: CGFloat
	@State private var dragStartWidth: CGFloat?

	var body: some View {
		Rectangle()
			.fill(Color(NSColor.separatorColor))
			.frame(width: 1)
			.frame(maxHeight: .infinity)
			.overlay(
				Rectangle()
					.fill(Color.clear)
					.contentShape(Rectangle())
					.frame(width: 6)
					.onHover { hovering in
						if hovering {
							NSCursor.resizeLeftRight.push()
						} else {
							NSCursor.pop()
						}
					}
					.gesture(
						DragGesture(minimumDistance: 0)
							.onChanged { value in
								if dragStartWidth == nil {
									dragStartWidth = width
								}
								// Drawer is on the trailing edge: dragging the
								// handle leftward (negative translation.width)
								// must grow the drawer.
								let proposed = (dragStartWidth ?? width) - value.translation.width
								width = max(minWidth, min(maxWidth, proposed))
							}
							.onEnded { _ in
								dragStartWidth = nil
							}
					)
			)
	}
}

/// Single-line yellow banner shown at the top of MainWindow when a setting
/// only takes effect on new surfaces (scrollback / titlebar). The user can
/// dismiss it with the trailing close button.
struct Banner: View {
	let text: String
	let onDismiss: () -> Void

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: "info.circle.fill")
				.foregroundStyle(.yellow)
			Text(text)
				.font(.callout)
			Spacer()
			Button(action: onDismiss) {
				Image(systemName: "xmark")
			}
			.buttonStyle(.plain)
			.help("Dismiss")
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
		.background(Color.yellow.opacity(0.15))
	}
}

/// Red banner listing Ghostty config diagnostics (e.g. "unknown key: foo").
/// Shown above MainWindow content while messages are present; dismissed by
/// the user once they have acknowledged the issues.
struct DiagnosticBanner: View {
	let messages: [String]
	let onDismiss: () -> Void

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundStyle(.red)
			VStack(alignment: .leading, spacing: 2) {
				Text("Config diagnostics")
					.font(.callout.weight(.semibold))
				ForEach(messages, id: \.self) { message in
					Text(message)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			Spacer()
			Button(action: onDismiss) {
				Image(systemName: "xmark")
			}
			.buttonStyle(.plain)
			.help("Dismiss")
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
		.background(Color.red.opacity(0.12))
	}
}
