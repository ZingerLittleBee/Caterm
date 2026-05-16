import AppKit
import QuartzCore

@MainActor
public enum TerminalWindowTransparency {
	public static func apply(enabled: Bool, to window: NSWindow?, layer: CALayer?) {
		layer?.isOpaque = !enabled
		guard let window else { return }

		window.alphaValue = 1.0
		if enabled {
			window.isOpaque = false
			window.backgroundColor = .clear
		} else {
			window.isOpaque = true
			window.backgroundColor = .windowBackgroundColor
		}
	}
}
