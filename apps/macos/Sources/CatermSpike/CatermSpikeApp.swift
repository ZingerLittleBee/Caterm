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
            // Spike S2: render the user's default shell. SSH comes in Task 5
            // by passing `command="ssh user@host"`.
            self.bridge = try GhosttyBridge(command: nil)
        } catch {
            self.error = "\(error)"
        }
    }
}
