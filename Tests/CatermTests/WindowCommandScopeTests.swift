import AppKit
import XCTest
@testable import Caterm

@MainActor
final class WindowCommandScopeTests: XCTestCase {
	func testBroadcastRoutesOnlyToKeyWindow() {
		let keyWindow = NSObject()
		let backgroundWindow = NSObject()

		XCTAssertTrue(
			WindowCommandScope.shouldHandle(
				notificationObject: nil,
				receiverWindow: keyWindow,
				receiverIsKeyWindow: true
			)
		)
		XCTAssertFalse(
			WindowCommandScope.shouldHandle(
				notificationObject: nil,
				receiverWindow: backgroundWindow,
				receiverIsKeyWindow: false
			)
		)
	}

	func testExplicitTargetRoutesOnlyToMatchingWindow() {
		let targetWindow = NSObject()
		let otherKeyWindow = NSObject()

		XCTAssertTrue(
			WindowCommandScope.shouldHandle(
				notificationObject: targetWindow,
				receiverWindow: targetWindow,
				receiverIsKeyWindow: false
			)
		)
		XCTAssertFalse(
			WindowCommandScope.shouldHandle(
				notificationObject: targetWindow,
				receiverWindow: otherKeyWindow,
				receiverIsKeyWindow: true
			)
		)
	}

	func testMissingReceiverNeverHandlesCommand() {
		XCTAssertFalse(
			WindowCommandScope.shouldHandle(
				notificationObject: nil,
				receiverWindow: nil,
				receiverIsKeyWindow: true
			)
		)
	}

	func testWorkspaceLifecycleCapturesWindowAndHandlesItsActualClose() throws {
		_ = NSApplication.shared
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		let lifecycleView = WorkspaceWindowLifecycleView()
		var capturedWindow: NSWindow?
		var closeCount = 0
		lifecycleView.onWindowChange = { capturedWindow = $0 }
		lifecycleView.onClose = { closeCount += 1 }
		let contentView = try XCTUnwrap(window.contentView)

		contentView.addSubview(lifecycleView)

		XCTAssertTrue(capturedWindow === window)
		XCTAssertEqual(closeCount, 0)
		window.close()
		XCTAssertEqual(closeCount, 1)

		lifecycleView.stopObserving()
		lifecycleView.onWindowChange = nil
		lifecycleView.onClose = nil
		lifecycleView.removeFromSuperview()
		capturedWindow = nil
	}
}
