@testable import CatermMobileTerminal
import XCTest

final class ChannelRequestReplyHandlerTests: XCTestCase {
	func testSerializedRepliesMapServerSuccessAndFailureToExactRequest() {
		let handler = ChannelRequestReplyHandler()
		var results: [Bool] = []

		handler.expectReply { results.append($0) }
		handler.receiveReply(true)
		handler.expectReply { results.append($0) }
		handler.receiveReply(false)

		XCTAssertEqual(results, [true, false])
	}

	func testClosingChannelClearsPendingRequestWithoutFabricatingRejection() {
		let handler = ChannelRequestReplyHandler()
		var results: [Bool] = []

		handler.expectReply { results.append($0) }
		handler.cancelPendingReply()
		handler.cancelPendingReply()

		XCTAssertEqual(results, [])
	}

	func testStaleTimeoutCannotCancelNextSerializedRequest() {
		let handler = ChannelRequestReplyHandler()
		var results: [Bool] = []

		let firstToken = handler.expectReply { results.append($0) }
		handler.receiveReply(true)
		let secondToken = handler.expectReply { results.append($0) }

		XCTAssertFalse(handler.cancelPendingReply(firstToken))
		XCTAssertTrue(handler.cancelPendingReply(secondToken))
		XCTAssertEqual(results, [true])
	}
}
