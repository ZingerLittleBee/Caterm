import XCTest
@testable import Caterm

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
}
