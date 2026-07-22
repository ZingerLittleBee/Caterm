import AppKit
import XCTest
@testable import TerminalEngine

@MainActor
final class TerminalPaneFocusTests: XCTestCase {
	func testProgrammaticFocusAndFirstResponderChangesAreReported() throws {
		_ = NSApplication.shared
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		let terminal = GhosttySurfaceNSView(
			command: nil,
			createsSurfaceOnAttach: false
		)
		terminal.setPaneFocusRequested(false)
		var changes: [Bool] = []
		terminal.onFirstResponderChange = { changes.append($0) }
		let contentView = try XCTUnwrap(window.contentView)
		contentView.addSubview(terminal)

		XCTAssertFalse(window.firstResponder === terminal)

		terminal.setPaneFocusRequested(true)

		XCTAssertTrue(window.firstResponder === terminal)
		XCTAssertEqual(changes, [true])

		terminal.setPaneFocusRequested(false)

		XCTAssertFalse(window.firstResponder === terminal)
		XCTAssertEqual(changes, [true, false])

		terminal.setPaneFocusRequested(true)
		window.makeFirstResponder(contentView)

		XCTAssertTrue(window.firstResponder === contentView)
		XCTAssertEqual(changes, [true, false, true, false])

		terminal.onFirstResponderChange = nil
		terminal.removeFromSuperview()
		window.close()
	}

	func testMouseDownActivatesPaneBeforeTerminalInput() throws {
		_ = NSApplication.shared
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		let first = GhosttySurfaceNSView(command: nil, createsSurfaceOnAttach: false)
		let second = GhosttySurfaceNSView(command: nil, createsSurfaceOnAttach: false)
		first.setPaneFocusRequested(false)
		second.setPaneFocusRequested(true)
		var firstBecameActive = false
		first.onFirstResponderChange = { focused in firstBecameActive = focused }
		let contentView = try XCTUnwrap(window.contentView)
		contentView.addSubview(first)
		contentView.addSubview(second)
		window.makeFirstResponder(second)
		let event = try XCTUnwrap(NSEvent.mouseEvent(
			with: .leftMouseDown,
			location: .zero,
			modifierFlags: [],
			timestamp: 0,
			windowNumber: window.windowNumber,
			context: nil,
			eventNumber: 1,
			clickCount: 1,
			pressure: 1
		))

		first.mouseDown(with: event)

		XCTAssertTrue(window.firstResponder === first)
		XCTAssertTrue(firstBecameActive)
		first.onFirstResponderChange = nil
		first.removeFromSuperview()
		second.removeFromSuperview()
		window.close()
	}
}
