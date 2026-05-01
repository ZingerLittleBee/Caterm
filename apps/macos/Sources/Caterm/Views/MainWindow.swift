import AppKit
import FileTransferStore
import SessionStore
import SFTPCommandBuilder
import SSHCommandBuilder
import SwiftUI

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
	@State private var fileDrawerOpen = false
	let tabId: UUID

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
		NavigationSplitView {
			// Already a tab — connecting from this sidebar should spawn a
			// sibling tabbed window (auto-merged by macOS into the current
			// tab bar), not replace this window's session.
			HostListSidebar(onOpenTab: { newId in openWindow(value: newId) })
				.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
		} detail: {
			HSplitView {
				Group {
					if store.tabs.contains(where: { $0.id == tabId }) {
						TerminalContainerView(tabId: tabId)
					} else {
						Text("Tab closed")
							.foregroundColor(.secondary)
					}
				}
				.frame(minWidth: 400, minHeight: 500)

				if fileDrawerOpen {
					FileDrawerView(
						host: activeHost,
						fs: activeRemoteFs,
						fileTransferStore: fileTransferStore
					)
						.frame(minWidth: 240, idealWidth: 320, maxWidth: 600)
				}
			}
			.frame(minHeight: 500)
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
		.onDisappear { store.closeTab(tabId: tabId) }
	}
}
