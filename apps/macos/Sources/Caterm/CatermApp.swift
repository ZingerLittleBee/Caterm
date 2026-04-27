import SwiftUI

@main
struct CatermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            Text("Caterm — Phase 1 scaffold")
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}
