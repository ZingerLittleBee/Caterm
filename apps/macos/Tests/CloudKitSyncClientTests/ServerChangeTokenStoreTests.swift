import CloudKit
import XCTest
@testable import CloudKitSyncClient

final class StoredServerChangeTokenTests: XCTestCase {
	func testRoundTripPreservesArchivedDataEquality() throws {
		throw XCTSkip("requires FakeCloudDatabase.makeRealishToken from Task 1.5")
	}

	func testUnarchiveReturnsEquivalentToken() throws {
		throw XCTSkip("requires FakeCloudDatabase.makeRealishToken from Task 1.5")
	}

	func testUnarchiveOnGarbageThrows() {
		let stored = StoredServerChangeToken(archivedData: Data([0xDE, 0xAD, 0xBE, 0xEF]))
		XCTAssertThrowsError(try stored.unarchive())
	}
}
