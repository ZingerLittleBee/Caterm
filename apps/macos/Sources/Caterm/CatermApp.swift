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
		// File > New Window default; show the landing screen prompting ⌘T.
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
			// Replace the default "New Window" with ⌘T → New Tab. macOS's
			// auto-tabbing groups subsequent windows of the same WindowGroup
			// into the active window's native tab bar.
			CommandGroup(replacing: .newItem) {
				Button("New Tab") { newTab(store: store) }
					.keyboardShortcut("t", modifiers: .command)
			}
		}
	}
}

/// Posts a request to open a new tab window. The actual `openWindow(value:)`
/// call needs `@Environment(\.openWindow)` which is only available inside a
/// View body — `OpenTabBridge` (mounted in every window) listens for this
/// notification and routes through to the environment value.
@MainActor
private func newTab(store: SessionStore) {
	// Task 1.5: still hardcoded smoke host; Task 1.6 replaces this with a real
	// host picker / connect dialog.
	let host = SSHHost(
		id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
		name: "smoke-\(store.tabs.count)",
		hostname: "127.0.0.1", port: 2222,
		username: "spike", credential: .password
	)
	// Stuff Keychain (idempotent — replaces if exists)
	let kc = KeychainStore(service: "com.caterm.host",
	                       accessGroup: store.accessGroup)
	try? kc.set(account: "\(host.id.uuidString).password", secret: "spikepass")
	let tabId = store.openTab(host: host)
	NotificationCenter.default.post(
		name: .catermOpenTab, object: nil, userInfo: ["tabId": tabId]
	)
}

extension Notification.Name {
	static let catermOpenTab = Notification.Name("CatermOpenTabNotification")
}

/// Invisible bridge view that lets us call `openWindow(value:)` (which needs
/// the `@Environment(\.openWindow)` from inside a SwiftUI View) in response to
/// a NotificationCenter post from the App-level `newTab` command.
///
/// Mounted in every window's `.background` so any window's environment can
/// drive the new-tab opening — macOS auto-tabbing then merges the resulting
/// new window into the active window's tab bar.
private struct OpenTabBridge: View {
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
/// Once Task 1.6 lands, this is replaced by the host list / connect dialog.
struct LandingView: View {
	var body: some View {
		VStack(spacing: 12) {
			Text("Caterm").font(.largeTitle)
			Text("⌘T to open a new SSH tab")
				.foregroundColor(.secondary)
		}
		.frame(minWidth: 800, minHeight: 500)
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

	// Dev: askpass binary path can be overridden via env. In a packaged .app
	// it would sit alongside the main binary in Contents/MacOS/.
	let askpassPath = ProcessInfo.processInfo.environment["CATERM_DEV_ASKPASS_PATH"]
		?? Bundle.main.bundleURL
		.deletingLastPathComponent()
		.appendingPathComponent("caterm-askpass").path

	// Task 1.3 finding: AMFI rejects keychain-access-groups on dev signing.
	// In dev path we leave accessGroup nil and fall back to the login keychain.
	let teamId = ProcessInfo.processInfo.environment["CATERM_TEAM_ID"] ?? ""
	let accessGroup = teamId.isEmpty ? nil : "\(teamId).caterm.shared"

	return SessionStore(askpassPath: askpassPath,
	                    knownHostsCaterm: knownCaterm,
	                    knownHostsUser: knownUser,
	                    accessGroup: accessGroup)
}
