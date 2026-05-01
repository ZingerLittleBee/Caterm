import AppKit
import FileTransferStore
import SessionStore
import SFTPCommandBuilder
import SSHCommandBuilder
import SwiftUI
import TerminalEngine

/// Content of one window in the multi-tab `WindowGroup(for: UUID.self)`. Each
/// SwiftUI window represents one SessionStore tab; macOS merges them into
/// native tabs because `NSWindow.allowsAutomaticWindowTabbing = true` (set in
/// `AppDelegate`).
///
/// Closing the window (⌘W on the active tab) deinits this view tree. The
/// `.onDisappear` hook keeps `SessionStore.tabs` in sync; surface destruction
/// (and the resulting SIGHUP to ssh) happens via `GhosttySurfaceNSView.deinit`.
struct MainWindow: View {
	@EnvironmentObject var store: SessionStore
	@EnvironmentObject var fileTransferStore: FileTransferStore
	@Environment(\.openWindow) private var openWindow
	@StateObject private var bannerState = SettingsBannerState()
	@State private var fileDrawerOpen = false
	@State private var drawerWidth: CGFloat = 320
	@State private var pendingUploadURLs: [URL] = []
	@State private var showUploadSheet = false
	let tabId: UUID

	private static let drawerMinWidth: CGFloat = 240
	private static let drawerMaxWidth: CGFloat = 600

	/// Host backing the active tab — `nil` once the tab has been closed.
	private var activeHost: SSHHost? {
		store.tabs.first(where: { $0.id == tabId })?.host
	}

	/// Recomputes a `RemoteFileSystem` actor for the active host on each
	/// render. The actor itself is cheap (no I/O at init); the underlying
	/// SFTP subprocess is only spawned when `list()` runs. Re-creating per
	/// render keeps `MainWindow` stateless about transfer plumbing — an
	/// optimization (caching by `host.id`) can come later if needed.
	private var activeRemoteFs: RemoteFileSystem? {
		guard let host = activeHost else { return nil }
		let cm = ControlMasterManager.shared
		let socket = cm.socketPath(for: host.id)
		let creds = SFTPCredentials(
			askpassPath: URL(fileURLWithPath: store.askpassPath),
			identityFiles: [],
			knownHostsCaterm: URL(fileURLWithPath: store.knownHostsCaterm),
			knownHostsUser: URL(fileURLWithPath: store.knownHostsUser),
			strictHostKeyChecking: .acceptNew
		)
		return RemoteFileSystem(
			host: host,
			controlPath: socket,
			credentials: creds,
			liveness: cm
		)
	}

	var body: some View {
		VStack(spacing: 0) {
			// Banners collapse to nothing when their state is empty, so for
			// the common case the layout is identical to the pre-banner
			// version. They sit above the split view so users see them
			// regardless of which sidebar/drawer is open.
			if !bannerState.diagnosticMessages.isEmpty {
				DiagnosticBanner(
					messages: bannerState.diagnosticMessages,
					onDismiss: bannerState.dismissDiagnostics
				)
			}
			if bannerState.showNewSurfaceBanner {
				Banner(
					text: "Some settings (scrollback / titlebar) apply to new tabs only.",
					onDismiss: bannerState.dismissNewSurface
				)
			}
			NavigationSplitView {
				// Already a tab — connecting from this sidebar should spawn a
				// sibling tabbed window (auto-merged by macOS into the current
				// tab bar), not replace this window's session.
				HostListSidebar(onOpenTab: { newId in openWindow(value: newId) })
					.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
			} detail: {
				// HStack instead of HSplitView: SwiftUI HSplitView caches its
				// underlying NSSplitView pane positions when a conditional
				// child is removed, leaving a dead, non-clickable band where
				// the drawer used to be. HStack reflows cleanly. Drag-resize
				// is reimplemented via DrawerDragHandle to keep parity with
				// the prior HSplitView UX. We can't simply force HSplitView
				// to rebuild via .id() — that would tear down
				// TerminalSurfaceRepresentable and SIGHUP the live ssh
				// session.
				HStack(spacing: 0) {
					Group {
						if store.tabs.contains(where: { $0.id == tabId }) {
							TerminalContainerView(tabId: tabId)
						} else {
							Text("Tab closed")
								.foregroundColor(.secondary)
						}
					}
					.frame(
						minWidth: 400,
						maxWidth: .infinity,
						minHeight: 500,
						maxHeight: .infinity
					)
					.layoutPriority(0)

					if fileDrawerOpen {
						DrawerDragHandle(
							width: $drawerWidth,
							minWidth: Self.drawerMinWidth,
							maxWidth: Self.drawerMaxWidth
						)
						.layoutPriority(1)
						FileDrawerView(
							host: activeHost,
							fs: activeRemoteFs,
							fileTransferStore: fileTransferStore
						)
						.frame(width: drawerWidth, alignment: .leading)
						.frame(minHeight: 500, maxHeight: .infinity)
						.layoutPriority(1)
					}
				}
				// Disable implicit animations on this subtree. NavigationSplitView's
				// sidebar collapse/expand animates the detail container's frame;
				// without this, SwiftUI animates the HStack children during that
				// transition and the drawer briefly translates left then snaps
				// back as the layout settles.
				.transaction { $0.animation = nil }
				// Detail floor: terminal min + drawer min + handle when drawer
				// is open. Without it the NavigationSplitView lets the detail
				// steal width from the sidebar's 220pt floor.
				.frame(minWidth: fileDrawerOpen ? 400 + Self.drawerMinWidth + 1 : 400, minHeight: 500)
			}
		}
		.frame(minWidth: 1000, minHeight: 600)
		.toolbar {
			ToolbarItemGroup(placement: .primaryAction) {
				Button {
					fileDrawerOpen.toggle()
				} label: {
					Image(systemName: "folder")
				}
				.help("Toggle Files Drawer (⌘⇧F)")
			}
		}
		.onReceive(NotificationCenter.default
			.publisher(for: .toggleFileDrawer)) { _ in
			fileDrawerOpen.toggle()
		}
		.onReceive(NotificationCenter.default
			.publisher(for: .catermOptionDragUpload)) { note in
			guard let urls = note.userInfo?["urls"] as? [URL], !urls.isEmpty else { return }
			pendingUploadURLs = urls
			showUploadSheet = true
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
		.onDisappear { store.closeTab(tabId: tabId) }
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
