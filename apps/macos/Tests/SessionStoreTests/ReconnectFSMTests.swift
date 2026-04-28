import XCTest
@testable import SessionStore

final class ReconnectFSMTests: XCTestCase {
	func testBackoffSchedule() {
		XCTAssertEqual(ReconnectScheduler.backoff(attempt: 1), 1.0)
		XCTAssertEqual(ReconnectScheduler.backoff(attempt: 2), 2.0)
		XCTAssertEqual(ReconnectScheduler.backoff(attempt: 3), 5.0)
		XCTAssertEqual(ReconnectScheduler.backoff(attempt: 4), 10.0)
		XCTAssertEqual(ReconnectScheduler.backoff(attempt: 5), 30.0)
	}

	func testMaxAttempts() {
		XCTAssertEqual(ReconnectScheduler.maxAttempts, 5)
	}

	func testShouldReconnectAfterConnectionDropped() {
		XCTAssertTrue(ReconnectScheduler.shouldReconnect(failureKind: .connectionDropped, attempt: 1))
		XCTAssertTrue(ReconnectScheduler.shouldReconnect(failureKind: .connectionDropped, attempt: 5))
		XCTAssertFalse(ReconnectScheduler.shouldReconnect(failureKind: .connectionDropped, attempt: 6))
	}

	func testNeverReconnectAuthFail() {
		XCTAssertFalse(ReconnectScheduler.shouldReconnect(failureKind: .authOrSetupFail, attempt: 1))
	}

	func testNeverReconnectCleanExit() {
		XCTAssertFalse(ReconnectScheduler.shouldReconnect(failureKind: .cleanExit, attempt: 1))
	}
}
