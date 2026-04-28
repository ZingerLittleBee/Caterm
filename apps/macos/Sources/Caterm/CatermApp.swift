import ConfigStore
import HostSyncStore
import KeychainStore
import ServerSyncClient
import SessionStore
import SSHCommandBuilder
import SwiftUI
import TerminalEngine

@main
struct CatermApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
	@StateObject var store: SessionStore = makeStore()
	@State private var showSyncSettings = false
	@State private var serverURLText: String = ServerURL.current.absoluteString
	private let authSession = AuthSession(baseURL: ServerURL.current)
	private let syncClient: ServerSyncClient = URLSessionServerSyncClient(baseURL: ServerURL.current)

	@MainActor
	private var syncStore: HostSyncStore {
		HostSyncStore(client: syncClient, sessionStore: store, authSession: authSession)
	}

	init() {
		try? ConfigStore.ensureExists(at: ConfigStore.defaultPath)
	}

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
			.sheet(isPresented: $showSyncSettings) {
				SyncSettingsView(
					authSession: authSession,
					syncStore: syncStore,
					serverURL: $serverURLText
				)
				.onChange(of: serverURLText) { _, newValue in
					if let url = URL(string: newValue), !newValue.isEmpty {
						ServerURL.set(url)
					}
				}
			}
		}
		.commands {
			// ⌘N opens a fresh LandingView window (OpenTabBridge handles the
			// notification by calling openWindow(value: UUID())).
			// ⌘T adds a new host (the sidebar listens and opens its add-sheet).
			CommandGroup(replacing: .newItem) {
				Button("New Window") {
					NotificationCenter.default.post(name: .catermNewWindow, object: nil)
				}
				.keyboardShortcut("n", modifiers: .command)
				Button("New Host…") {
					NotificationCenter.default.post(name: .catermAddHost, object: nil)
				}
				.keyboardShortcut("t", modifiers: .command)
			}
			// ⌘, opens (reveals) the TOML config file in Finder.
			CommandGroup(replacing: .appSettings) {
				Button("Settings…") {
					ConfigStore.revealInFinder(ConfigStore.defaultPath)
				}
				.keyboardShortcut(",", modifiers: .command)
			}
			CommandGroup(after: .appSettings) {
				Button("Sync Settings…") { showSyncSettings = true }
					.keyboardShortcut(",", modifiers: [.command, .shift])
			}
			// Help menu → GitHub documentation page.
			CommandGroup(replacing: .help) {
				Link("Caterm Documentation",
				     destination: URL(string: "https://github.com/ZingerLittleBee/Caterm")!)
			}
		}
	}
}

extension Notification.Name {
	static let catermOpenTab = Notification.Name("CatermOpenTabNotification")
	static let catermAddHost = Notification.Name("CatermAddHostNotification")
	static let catermNewWindow = Notification.Name("CatermNewWindowNotification")
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
			.onReceive(NotificationCenter.default.publisher(for: .catermNewWindow)) { _ in
				// A fresh UUID that is not in store.tabs causes WindowGroup to
				// render LandingView rather than MainWindow — effectively a new
				// blank window in the tab bar.
				openWindow(value: UUID())
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
