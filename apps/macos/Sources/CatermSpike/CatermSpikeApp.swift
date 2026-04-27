import SwiftUI

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
        Text("Spike alive")
            .font(.system(size: 24, design: .monospaced))
            .padding()
    }
}
