import XCTest
@testable import SessionStore

final class ConnectionStateTests: XCTestCase {
	func testStatesAreDistinct() {
		let now = Date()
		XCTAssertNotEqual(ConnectionState.idle, .preflight(startedAt: now))
		XCTAssertNotEqual(ConnectionState.preflight(startedAt: now),
						  .authenticating(startedAt: now))
		XCTAssertNotEqual(ConnectionState.authenticating(startedAt: now),
						  .connected(connectedAt: now))
	}

	func testEqualityRespectsAssociatedDate() {
		let t1 = Date(timeIntervalSince1970: 1000)
		let t2 = Date(timeIntervalSince1970: 2000)
		XCTAssertEqual(ConnectionState.preflight(startedAt: t1),
					   ConnectionState.preflight(startedAt: t1))
		XCTAssertNotEqual(ConnectionState.preflight(startedAt: t1),
						  ConnectionState.preflight(startedAt: t2))
	}
}
