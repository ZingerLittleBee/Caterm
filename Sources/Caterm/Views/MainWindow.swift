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
import WorkspaceCore

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
	@Environment(\.openWindow) private var openWindow
	@StateObject private var bannerState = SettingsBannerState()
	@State private var fileDrawerOpen = false
	@State private var drawerWidth: CGFloat = 320
	@State private var pendingUploadURLs: [URL] = []
	@State private var showUploadSheet = false
	@State private var presentingPalette = false
	@State private var presentingEditor = false
	@State private var presentingManager = false
	@State private var hostWindow: NSWindow?
	@State private var remoteFsCache = RemoteFsCache()
	@State private var restorationStatus = WorkspaceRestorationStatus.pending
	@Binding var workspace: Workspace

	private static let drawerMinWidth: CGFloat = 240
	private static let drawerMaxWidth: CGFloat = 600

	private var activeSessionID: UUID? {
		workspaceCoordinator.sessionID(for: workspace)
	}

	/// Host backing the active Pane's runtime session.
	private var activeHost: SSHHost? {
		guard let activeSessionID else { return nil }
		return store.tabs.first(where: { $0.id == activeSessionID })?.host
	}

	private var skippedForwardBannerText: String {
		let scoped = store.skippedForwardNotices.filter {
			$0.hostId == activeHost?.id
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
	/// `RemoteFsCache` keeps a stable instance keyed by `host.id`.
	private var activeRemoteFs: RemoteFileSystem? {
		guard let host = activeHost else { return nil }
		return remoteFsCache.fileSystem(for: host) {
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
			// Banners collapse to nothing when their state is empty, so for
			// the common case the layout is identical to the pre-banner
			// version. They sit above the split view so users see them
			// regardless of which sidebar/drawer is open.
			if !skippedForwardBannerText.isEmpty {
				Banner(
					text: skippedForwardBannerText,
					onDismiss: { store.clearSkippedForwardNotices(forHost: activeHost?.id) }
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
									restorationMessage: restorationMessage
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
								host: activeHost,
								fs: activeRemoteFs,
								fileTransferStore: fileTransferStore
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
				.animation(.easeInOut(duration: 0.22), value: fileDrawerOpen)
			}
		}
		.frame(minWidth: 1000, minHeight: 600)
		.toolbar {
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
			pendingUploadURLs = urls
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
		.sheet(isPresented: $showUploadSheet) {
			SimpleTextSheet(
				title: "Upload to remote directory",
				prompt: "Path",
				initialValue: "~",
				onSubmit: { remoteDir in
					showUploadSheet = false
					if let host = activeHost, !pendingUploadURLs.isEmpty {
						_ = fileTransferStore.enqueueUpload(
							localPaths: pendingUploadURLs,
							remoteDir: remoteDir,
							host: host
						)
					}
					pendingUploadURLs = []
				},
				onCancel: {
					showUploadSheet = false
					pendingUploadURLs = []
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
		.task(id: workspace.id) {
			do {
				try workspaceCoordinator.ensureSessions(
					for: workspace,
					installTerminfo: preferences.installTerminfoEnabled
				)
				let hasMissingHost = workspace.topology.panes.contains { pane in
					pane.host != nil
						&& workspaceCoordinator.sessionID(for: pane.id, in: workspace) == nil
				}
				restorationStatus = hasMissingHost ? .missingHost : .ready
			} catch {
				restorationStatus = .failed(error.localizedDescription)
			}
		}
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

/// Caches one `RemoteFileSystem` per `host.id` so a stable instance
/// survives unrelated `MainWindow` re-renders. Reference type held via
/// `@State`, so SwiftUI keeps the same cache across the view's lifetime.
/// The cached instance is replaced only when the active host changes.
@MainActor
final class RemoteFsCache {
	private var cached: (hostId: UUID, fs: RemoteFileSystem)?

	func fileSystem(for host: SSHHost, make: () -> RemoteFileSystem) -> RemoteFileSystem {
		if let cached, cached.hostId == host.id { return cached.fs }
		let fs = make()
		cached = (host.id, fs)
		return fs
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
