import KeychainStore
import SessionStore
import SSHCommandBuilder
import SwiftUI
import TerminalEngine

@main
struct CatermApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
	@StateObject var store: SessionStore = makeStore()

	var body: some Scene {
		// Each tab in the OS-provided native tab bar is one window in this
		// `WindowGroup(for: UUID.self)`. macOS auto-tabs them because
		// `NSWindow.allowsAutomaticWindowTabbing = true` (AppDelegate).
		//
		// When `tabId == nil` the user opened a "fresh" window via the
		// File > New Window default; show the landing screen with the host
		// list sidebar.
		WindowGroup(for: UUID.self) { $tabId in
			Group {
				if let id = tabId, store.tabs.contains(where: { $0.id == id }) {
					MainWindow(tabId: id)
				} else {
					LandingView()
				}
			}
			.environmentObject(store)
			.background(OpenTabBridge(store: store))
		}
		.commands {
			// ⌘T now means "add a new host" (the sidebar listens for this
			// notification and opens its add-sheet). Connecting to a host
			// happens via the sidebar (Connect / double-click).
			CommandGroup(replacing: .newItem) {
				Button("New Host…") {
					NotificationCenter.default.post(name: .catermAddHost, object: nil)
				}
				.keyboardShortcut("t", modifiers: .command)
			}
		}
	}
}

extension Notification.Name {
	static let catermOpenTab = Notification.Name("CatermOpenTabNotification")
	static let catermAddHost = Notification.Name("CatermAddHostNotification")
}

/// Invisible bridge view that lets us call `openWindow(value:)` (which needs
/// the `@Environment(\.openWindow)` from inside a SwiftUI View) in response to
/// a NotificationCenter post from anywhere (HostListSidebar's Connect action).
///
/// Mounted in every window's `.background` so any window's environment can
/// drive the new-tab opening — macOS auto-tabbing then merges the resulting
/// new window into the active window's tab bar.
struct OpenTabBridge: View {
	@Environment(\.openWindow) var openWindow
	let store: SessionStore

	var body: some View {
		Color.clear
			.frame(width: 0, height: 0)
			.onReceive(NotificationCenter.default.publisher(for: .catermOpenTab)) { note in
				guard let tabId = note.userInfo?["tabId"] as? UUID else { return }
				openWindow(value: tabId)
			}
	}
}

/// Initial landing view shown when a "fresh" (tabId-less) window opens.
/// Embeds the host list sidebar so users can manage hosts before any tab
/// is open.
struct LandingView: View {
	var body: some View {
		NavigationSplitView {
			HostListSidebar()
				.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
		} detail: {
			VStack(spacing: 12) {
				Image(systemName: "terminal").font(.system(size: 64))
					.foregroundColor(.secondary)
				Text("Caterm").font(.largeTitle)
				Text("Pick a host from the sidebar, or press ⌘T to add one")
					.foregroundColor(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.frame(minWidth: 1000, minHeight: 600)
	}
}

@MainActor
private func makeStore() -> SessionStore {
	let supportDir = FileManager.default
		.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		.appendingPathComponent("Caterm", isDirectory: true)
	try? FileManager.default.createDirectory(at: supportDir,
	                                         withIntermediateDirectories: true)
	let knownCaterm = supportDir.appendingPathComponent("known_hosts").path
	let knownUser = ("~/.ssh/known_hosts" as NSString).expandingTildeInPath
	let hostsURL = supportDir.appendingPathComponent("hosts.json")

	// Dev: askpass binary path can be overridden via env. In a packaged .app
	// it would sit alongside the main binary in Contents/MacOS/.
	// For a SwiftPM CLI executable, `Bundle.main.executableURL` is the binary
	// itself; its parent directory contains the sibling `caterm-askpass`.
	let askpassPath = ProcessInfo.processInfo.environment["CATERM_DEV_ASKPASS_PATH"]
		?? Bundle.main.executableURL!
		.deletingLastPathComponent()
		.appendingPathComponent("caterm-askpass").path

	// Task 1.3 finding: AMFI rejects keychain-access-groups on dev signing.
	// In dev path we leave accessGroup nil and fall back to the login keychain.
	let teamId = ProcessInfo.processInfo.environment["CATERM_TEAM_ID"] ?? ""
	let accessGroup = teamId.isEmpty ? nil : "\(teamId).caterm.shared"

	let keychain = KeychainStore(service: "com.caterm.host", accessGroup: accessGroup)

	return SessionStore(askpassPath: askpassPath,
	                    knownHostsCaterm: knownCaterm,
	                    knownHostsUser: knownUser,
	                    accessGroup: accessGroup,
	                    hostsURL: hostsURL,
	                    keychain: keychain)
}
