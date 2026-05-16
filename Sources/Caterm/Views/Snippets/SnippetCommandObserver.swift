import AppKit
import SnippetSyncClient
import SwiftUI

struct SnippetCommandObserver: ViewModifier {
	@Binding var presentingPalette: Bool
	@Binding var presentingEditor: Bool
	@Binding var presentingManager: Bool

	let isKeyWindow: () -> Bool

	func body(content: Content) -> some View {
		content
			.onReceive(NotificationCenter.default.publisher(for: .catermOpenSnippetPalette)) { _ in
				if isKeyWindow() { presentingPalette = true }
			}
			.onReceive(NotificationCenter.default.publisher(for: .catermNewSnippet)) { _ in
				if isKeyWindow() { presentingEditor = true }
			}
			.onReceive(NotificationCenter.default.publisher(for: .catermOpenSnippetManager)) { _ in
				if isKeyWindow() { presentingManager = true }
			}
	}
}

struct WindowAccessor: NSViewRepresentable {
	@Binding var window: NSWindow?
	func makeNSView(context: Context) -> NSView {
		let v = NSView()
		DispatchQueue.main.async { self.window = v.window }
		return v
	}
	func updateNSView(_ nsView: NSView, context: Context) {}
}
