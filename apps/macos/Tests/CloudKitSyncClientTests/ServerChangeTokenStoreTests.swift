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

	func testUnarchiveOnGarbageThrows() throws {
		throw XCTSkip("requires FakeCloudDatabase.makeRealishToken from Task 1.5")
	}
}
