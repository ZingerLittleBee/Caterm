import AppKit
import SessionStore
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
	@Environment(\.openWindow) private var openWindow
	let tabId: UUID

	var body: some View {
		NavigationSplitView {
			// Already a tab — connecting from this sidebar should spawn a
			// sibling tabbed window (auto-merged by macOS into the current
			// tab bar), not replace this window's session.
			HostListSidebar(onOpenTab: { newId in openWindow(value: newId) })
				.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
		} detail: {
			Group {
				if store.tabs.contains(where: { $0.id == tabId }) {
					TerminalContainerView(tabId: tabId)
				} else {
					Text("Tab closed")
						.foregroundColor(.secondary)
				}
			}
			.frame(minWidth: 600, minHeight: 500)
		}
		.frame(minWidth: 1000, minHeight: 600)
		.onDisappear { store.closeTab(tabId: tabId) }
	}
}
