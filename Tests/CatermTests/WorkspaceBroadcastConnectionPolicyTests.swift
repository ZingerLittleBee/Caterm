import SessionStore
import XCTest
@testable import Caterm

final class WorkspaceBroadcastConnectionPolicyTests: XCTestCase {
	func testProvisionalConnectedStateIsNotEligible() {
		XCTAssertFalse(WorkspaceBroadcastConnectionPolicy.isEligible(
			state: .connected(connectedAt: Date()),
			hadConfirmedConnection: false
		))
	}

	func testConfirmedConnectedStateIsEligible() {
		XCTAssertTrue(WorkspaceBroadcastConnectionPolicy.isEligible(
			state: .connected(connectedAt: Date()),
			hadConfirmedConnection: true
		))
	}

	func testPreviouslyConnectedButDisconnectedStateIsNotEligible() {
		XCTAssertFalse(WorkspaceBroadcastConnectionPolicy.isEligible(
			state: .failed(.connectionDropped),
			hadConfirmedConnection: true
		))
	}
}
