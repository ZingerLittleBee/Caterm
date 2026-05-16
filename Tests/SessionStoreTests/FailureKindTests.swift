import XCTest
@testable import SessionStore

final class FailureKindTests: XCTestCase {
	func testClassifyExitZeroIsCleanExit() {
		XCTAssertEqual(FailureKind.classify(exitCode: 0, hadConnected: false), .cleanExit)
		XCTAssertEqual(FailureKind.classify(exitCode: 0, hadConnected: true), .cleanExit)
	}

	func testClassifyAfterConnectedIsConnectionDropped() {
		XCTAssertEqual(FailureKind.classify(exitCode: 1, hadConnected: true), .connectionDropped)
	}

	func testClassifyBeforeConnectedIsAuthOrSetupFail() {
		XCTAssertEqual(FailureKind.classify(exitCode: 255, hadConnected: false), .authOrSetupFail)
	}

	func testNetworkErrorReasonEquality() {
		XCTAssertEqual(NetworkErrorReason.dnsFailed, .dnsFailed)
		XCTAssertNotEqual(NetworkErrorReason.dnsFailed, .timedOut)
		XCTAssertEqual(NetworkErrorReason.invalidPort(99999), .invalidPort(99999))
		XCTAssertNotEqual(NetworkErrorReason.invalidPort(99999), .invalidPort(0))
		XCTAssertEqual(
			NetworkErrorReason.other(code: 1, message: "x"),
			.other(code: 1, message: "x")
		)
	}

	func testFailureKindNetworkUnreachableEquality() {
		XCTAssertEqual(
			FailureKind.networkUnreachable(.dnsFailed),
			FailureKind.networkUnreachable(.dnsFailed)
		)
		XCTAssertNotEqual(
			FailureKind.networkUnreachable(.dnsFailed),
			FailureKind.networkUnreachable(.timedOut)
		)
	}

	func testNetworkUnreachableDoesNotAutoReconnect() {
		XCTAssertFalse(ReconnectScheduler.shouldReconnect(
			failureKind: .networkUnreachable(.dnsFailed), attempt: 1))
	}
}
