import SwiftUI
import GhosttyKit

@main
struct CatermSpikeApp: App {
    var body: some Scene {
        WindowGroup("Caterm Spike") {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Spike alive")
                .font(.system(size: 24, design: .monospaced))
            Text("libghostty linked: \(libghosttyVersion())")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func libghosttyVersion() -> String {
        if let cString = ghostty_info().version {
            return String(cString: cString)
        }
        return "unknown"
    }
}
