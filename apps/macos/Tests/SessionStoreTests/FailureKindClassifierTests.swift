import XCTest
@testable import SessionStore

final class FailureKindClassifierTests: XCTestCase {
    func testCleanExit() {
        XCTAssertEqual(FailureKind.classify(exitCode: 0, hadConnected: true), .cleanExit)
        XCTAssertEqual(FailureKind.classify(exitCode: 0, hadConnected: false), .cleanExit)
    }

    func testConnectionDroppedAfterConnected() {
        XCTAssertEqual(FailureKind.classify(exitCode: 1, hadConnected: true), .connectionDropped)
        XCTAssertEqual(FailureKind.classify(exitCode: 255, hadConnected: true), .connectionDropped)
    }

    func testAuthOrSetupFailEarly() {
        XCTAssertEqual(FailureKind.classify(exitCode: 255, hadConnected: false), .authOrSetupFail)
        XCTAssertEqual(FailureKind.classify(exitCode: 1, hadConnected: false), .authOrSetupFail)
    }
}
