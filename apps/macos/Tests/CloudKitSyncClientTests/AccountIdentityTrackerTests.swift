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

	func test_handleAccountChange_identityChange_resetsHostAndSnippet() async {
		defaults.set("USER-A", forKey: "cloudkit.lastKnownUserRecordName")
		let client = SpyClient()
		let tracker = AccountIdentityTracker(
			defaults: defaults,
			currentUserRecordID: { CKRecord.ID(recordName: "USER-B") },
			tokensExist: { true }
		)
		let outcome = await tracker.handleAccountChange(client: client)
		XCTAssertEqual(outcome, .identityChanged)
		XCTAssertTrue(client.didReset)
		XCTAssertTrue(client.didResetSnippet)
	}

	// Test-only spy; per-test instance, never accessed concurrently.
	private final class SpyClient: AccountSensitiveClient {
		nonisolated(unsafe) var didReset = false
		nonisolated(unsafe) var didDeleteSubscription = false
		nonisolated(unsafe) var didResetSnippet = false
		nonisolated(unsafe) var didDeleteSnippetSubscription = false
		func resetHostSyncState() async { didReset = true }
		func deleteHostSubscription() async throws { didDeleteSubscription = true }
		func resetSnippetSyncState() async { didResetSnippet = true }
		func deleteSnippetSubscription() async throws { didDeleteSnippetSubscription = true }
	}
}
