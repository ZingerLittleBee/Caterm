import CloudKit
import XCTest
@testable import CloudKitSyncClient

final class AccountIdentityTrackerTests: XCTestCase {
	private var defaults: UserDefaults!
	private var suiteName: String!

	override func setUp() async throws {
		suiteName = "AccountIdentityTrackerTests.\(UUID().uuidString)"
		defaults = UserDefaults(suiteName: suiteName)
	}

	override func tearDown() async throws {
		UserDefaults.standard.removePersistentDomain(forName: suiteName)
	}

	func testFirstObservationWithEmptyTokensStoresIdentityWithoutResetting() async {
		let client = SpyClient()
		let tracker = AccountIdentityTracker(
			defaults: defaults,
			currentUserRecordID: { CKRecord.ID(recordName: "USER-A") },
			tokensExist: { false }
		)
		await tracker.handleAccountChange(client: client)
		XCTAssertFalse(client.didReset)
		XCTAssertEqual(defaults.string(forKey: "cloudkit.lastKnownUserRecordName"), "USER-A")
	}

	func testFirstObservationWithExistingTokensCallsResetThenStores() async {
		let client = SpyClient()
		let tracker = AccountIdentityTracker(
			defaults: defaults,
			currentUserRecordID: { CKRecord.ID(recordName: "USER-A") },
			tokensExist: { true }
		)
		await tracker.handleAccountChange(client: client)
		XCTAssertTrue(client.didReset)
		XCTAssertEqual(defaults.string(forKey: "cloudkit.lastKnownUserRecordName"), "USER-A")
	}

	func testSameIdentityIsNoOp() async {
		defaults.set("USER-A", forKey: "cloudkit.lastKnownUserRecordName")
		let client = SpyClient()
		let tracker = AccountIdentityTracker(
			defaults: defaults,
			currentUserRecordID: { CKRecord.ID(recordName: "USER-A") },
			tokensExist: { true }
		)
		await tracker.handleAccountChange(client: client)
		XCTAssertFalse(client.didReset)
		XCTAssertFalse(client.didDeleteSubscription)
	}

	func testDifferentIdentityCallsResetAndDeleteSubscription() async {
		defaults.set("USER-A", forKey: "cloudkit.lastKnownUserRecordName")
		let client = SpyClient()
		let tracker = AccountIdentityTracker(
			defaults: defaults,
			currentUserRecordID: { CKRecord.ID(recordName: "USER-B") },
			tokensExist: { true }
		)
		await tracker.handleAccountChange(client: client)
		XCTAssertTrue(client.didReset)
		XCTAssertTrue(client.didDeleteSubscription)
		XCTAssertEqual(defaults.string(forKey: "cloudkit.lastKnownUserRecordName"), "USER-B")
	}

	func testSignOutAfterPriorIdentityCallsResetAndClears() async {
		defaults.set("USER-A", forKey: "cloudkit.lastKnownUserRecordName")
		let client = SpyClient()
		let tracker = AccountIdentityTracker(
			defaults: defaults,
			currentUserRecordID: { nil },
			tokensExist: { true }
		)
		await tracker.handleAccountChange(client: client)
		XCTAssertTrue(client.didReset)
		XCTAssertNil(defaults.string(forKey: "cloudkit.lastKnownUserRecordName"))
	}

	private final class SpyClient: AccountSensitiveClient {
		var didReset = false
		var didDeleteSubscription = false
		func resetHostSyncState() async { didReset = true }
		func deleteHostSubscription() async throws { didDeleteSubscription = true }
	}
}
