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
	@StateObject var store: SessionStore
	@StateObject var syncStore: HostSyncStore
	@StateObject var preferences: SyncPreferences
	@State private var showSyncSettings = false
	@State private var serverURLText: String = ServerURL.current.absoluteString
	private let authSession: AuthSession
	private let syncClient: ServerSyncClient

	init() {
		try? ConfigStore.ensureExists(at: ConfigStore.defaultPath)
		let session = makeStore()
		let auth = AuthSession(baseURL: ServerURL.current)
		let client = URLSessionServerSyncClient(baseURL: ServerURL.current)
		let prefs = SyncPreferences()
		// `_store = StateObject(wrappedValue:)` is the underscore-prefixed
		// property-wrapper init — required because `@StateObject` cannot be
		// assigned via the synthesized `self.store = ...` syntax in `init`.
		_store = StateObject(wrappedValue: session)
		_preferences = StateObject(wrappedValue: prefs)
		_syncStore = StateObject(wrappedValue: HostSyncStore(
			client: client,
			sessionStore: session,
			authSession: auth,
			preferences: prefs
		))
		self.authSession = auth
		self.syncClient = client
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
					// Pass the tabId binding so connecting from this Landing
					// window converts it into the new tab in place instead of
					// spawning a sibling blank tab.
					LandingView(tabId: $tabId)
				}
			}
			.environmentObject(store)
			.environmentObject(syncStore)        // NEW (v1.4)
			.environmentObject(preferences)      // NEW (v1.4)
			.background(OpenTabBridge(store: store))
			// .task closure is sync — syncIfSignedIn() returns immediately;
			// the actual sync work runs as an unstructured Task owned by
			// HostSyncStore.inFlight (NOT by this .task modifier). View
			// disappearance does not cancel the sync — that's intentional;
			// cancellation lives in the chain (spec §3.5).
			.task { syncStore.syncIfSignedIn() }
			.onReceive(NotificationCenter.default
				.publisher(for: .catermOpenSyncSettings)) { _ in   // NEW (v1.4)
				showSyncSettings = true
			}
			.sheet(isPresented: $showSyncSettings) {
				SyncSettingsView(
					authSession: authSession,
					syncStore: syncStore,
					preferences: preferences,
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
			// Edit menu pasteboard commands. Selectors are the standard
			// `NSText.copy/paste/pasteAsPlainText`, which AppKit
			// responder-chain-dispatches; whichever view is first responder
			// (e.g. GhosttySurfaceNSView) handles them.
			CommandGroup(replacing: .pasteboard) {
				Button("Copy") {
					NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
				}
				.keyboardShortcut("c", modifiers: [.command])

				Button("Paste") {
					NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
				}
				.keyboardShortcut("v", modifiers: [.command])

				Button("Paste and Match Style") {
					NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil)
				}
				.keyboardShortcut("v", modifiers: [.command, .option, .shift])
			}
			// ⌘⇧F toggles the per-window Files drawer. The notification is
			// observed by `MainWindow`; broadcasting via NotificationCenter
			// avoids threading window-local @State through App scene.
			CommandGroup(after: .toolbar) {
				Button("Toggle Files Drawer") {
					NotificationCenter.default.post(name: .toggleFileDrawer, object: nil)
				}
				.keyboardShortcut("f", modifiers: [.command, .shift])
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
	static let catermAddHost = Notification.Name("CatermAddHostNotification")
	static let catermNewWindow = Notification.Name("CatermNewWindowNotification")
}

/// Invisible bridge view that lets us call `openWindow(value:)` (which needs
/// `@Environment(\.openWindow)` from inside a SwiftUI View) in response to
/// the `.catermNewWindow` notification (⌘N).
///
/// Tab opening from the host list is NOT routed through here — it goes
/// through `HostListSidebar.onOpenTab`, so the owning window can decide
/// whether to swap its own tab identity (Landing case) or spawn a sibling
/// (MainWindow case). Routing it through a global notification used to
/// always spawn a sibling, which left the Landing window around as a blank
/// tab next to the new SSH terminal tab.
struct OpenTabBridge: View {
	@Environment(\.openWindow) var openWindow
	let store: SessionStore

	var body: some View {
		Color.clear
			.frame(width: 0, height: 0)
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
/// is open. When the user picks a host, swap our own `tabId` binding to
/// the new tab id — this morphs the current window from Landing into
/// MainWindow rather than spawning a separate window/tab.
struct LandingView: View {
	@Binding var tabId: UUID?

	var body: some View {
		NavigationSplitView {
			HostListSidebar(onOpenTab: { newId in tabId = newId })
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
