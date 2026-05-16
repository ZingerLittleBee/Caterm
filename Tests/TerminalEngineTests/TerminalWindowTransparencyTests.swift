import AppKit
import QuartzCore
import XCTest
@testable import TerminalEngine

@MainActor
final class TerminalWindowTransparencyTests: XCTestCase {
	func testTransparentBackgroundMakesWindowAndLayerNonOpaque() {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
		                      styleMask: [.titled],
		                      backing: .buffered,
		                      defer: false)
		let layer = CALayer()
		layer.isOpaque = true

		TerminalWindowTransparency.apply(enabled: true, to: window, layer: layer)

		XCTAssertFalse(window.isOpaque)
		XCTAssertEqual(window.backgroundColor, .clear)
		XCTAssertFalse(layer.isOpaque)
		XCTAssertEqual(window.alphaValue, 1.0)
	}

	func testOpaqueBackgroundRestoresWindowAndLayerOpacity() {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
		                      styleMask: [.titled],
		                      backing: .buffered,
		                      defer: false)
		let layer = CALayer()

		TerminalWindowTransparency.apply(enabled: true, to: window, layer: layer)
		TerminalWindowTransparency.apply(enabled: false, to: window, layer: layer)

		XCTAssertTrue(window.isOpaque)
		XCTAssertEqual(window.backgroundColor, .windowBackgroundColor)
		XCTAssertTrue(layer.isOpaque)
		XCTAssertEqual(window.alphaValue, 1.0)
	}
}
