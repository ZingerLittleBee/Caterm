import SwiftUI
import TerminalEngine

@main
struct CatermApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

	var body: some Scene {
		WindowGroup {
			TerminalSmokeView()
				.frame(minWidth: 800, minHeight: 500)
		}
	}
}

struct TerminalSmokeView: NSViewRepresentable {
	func makeNSView(context: Context) -> GhosttySurfaceNSView {
		// nil command -> libghostty runs the user's default $SHELL. Used as
		// the Task 1.1 smoke target; SSH command wiring lands in Task 1.4.
		GhosttySurfaceNSView(command: nil)
	}

	func updateNSView(_ view: GhosttySurfaceNSView, context: Context) {}
}
