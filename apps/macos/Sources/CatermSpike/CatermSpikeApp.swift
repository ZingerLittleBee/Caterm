import AppKit
import GhosttyKit
import SwiftUI

@main
struct CatermSpikeApp: App {
    @StateObject private var state = AppState()

    init() {
        // Running as a CLI binary without an .app bundle, so macOS treats us as
        // a background process. Force regular activation so the window comes
        // forward and accepts keyboard focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Caterm Spike") {
            Group {
                if let bridge = state.bridge {
                    TerminalView(bridge: bridge)
                } else if let err = state.error {
                    Text("Bridge init failed: \(err)")
                        .padding()
                } else {
                    Text("Initializing libghostty...")
                        .padding()
                }
            }
            .frame(minWidth: 800, minHeight: 500)
            .task { state.start() }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var bridge: GhosttyBridge?
    @Published var error: String?

    func start() {
        guard bridge == nil, error == nil else { return }
        do {
            // If SpikeConfig is available we set the surface command to
            // `ssh user@host`; otherwise we fall back to the user's default
            // shell so the binary is still useful without env vars.
            let command: String?
            if let cfg = try? SpikeConfig.load() {
                command = cfg.sshCommand()
            } else {
                command = nil
            }
            self.bridge = try GhosttyBridge(command: command)
        } catch {
            self.error = "\(error)"
        }
    }
}
