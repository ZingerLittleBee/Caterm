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
		WindowGroup {
			SmokeConnectView()
				.environmentObject(store)
				.frame(minWidth: 1000, minHeight: 600)
		}
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

	// Dev: askpass binary path can be overridden via env. In a packaged .app it
	// would sit alongside the main binary in Contents/MacOS/.
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

struct SmokeConnectView: View {
	@EnvironmentObject var store: SessionStore
	@State var tabId: UUID?

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Button("Connect to 127.0.0.1:2222 (spike/spikepass)") { connect() }
				Button("Disconnect") { disconnect() }
				if let tabId, let tab = store.tabs.first(where: { $0.id == tabId }) {
					Text("State: \(String(describing: tab.state))")
						.font(.system(.caption, design: .monospaced))
				}
			}.padding(8)
			if let tabId {
				ConnectedSurfaceView(tabId: tabId)
			} else {
				Text("Click Connect")
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
	}

	func connect() {
		let host = SSHHost(
			id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
			name: "smoke", hostname: "127.0.0.1", port: 2222,
			username: "spike", credential: .password
		)
		// Stuff Keychain (one-time per dev session — once stored, askpass reads it)
		let kc = KeychainStore(service: "com.caterm.host",
		                       accessGroup: store.accessGroup)
		try? kc.set(account: "\(host.id.uuidString).password", secret: "spikepass")

		tabId = store.openTab(host: host)
	}

	func disconnect() {
		// Task 1.5 wires close; for now just clear UI
		tabId = nil
	}
}

struct ConnectedSurfaceView: NSViewRepresentable {
	@EnvironmentObject var store: SessionStore
	let tabId: UUID

	func makeNSView(context: Context) -> GhosttySurfaceNSView {
		guard let cfg = store.surfaceConfig(for: tabId) else {
			return GhosttySurfaceNSView(command: nil)
		}
		let view = GhosttySurfaceNSView(command: cfg.command, env: cfg.env)
		store.markConnecting(tabId: tabId)

		// `view.surface` is built lazily in `viewDidMoveToWindow`. Hop a tick
		// later (after AppKit has attached the view) and wire callbacks then.
		let capturedTabId = tabId
		Task { @MainActor [weak store, weak view] in
			// Yield until the surface exists or we give up after ~3s.
			let deadline = Date().addingTimeInterval(3)
			while Date() < deadline {
				if let surface = view?.surface {
					surface.onChildExit = { [weak store] code in
						Task { @MainActor in
							store?.markChildExited(tabId: capturedTabId, exitCode: code)
						}
					}
					break
				}
				try? await Task.sleep(nanoseconds: 50_000_000)
			}
			// 3s grace period: if process still alive, mark Connected.
			try? await Task.sleep(nanoseconds: 3_000_000_000)
			guard let store, let surface = view?.surface, !surface.processExited else { return }
			store.markConnected(tabId: capturedTabId)
		}
		return view
	}

	func updateNSView(_: GhosttySurfaceNSView, context _: Context) {}
}
