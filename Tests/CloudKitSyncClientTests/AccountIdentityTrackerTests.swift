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
		XCTAssertTrue(client.didResetSnippet)
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
		let outcome = await tracker.handleAccountChange(client: client)
		XCTAssertTrue(client.didReset)
		XCTAssertTrue(client.didDeleteSubscription)
		XCTAssertEqual(outcome, .identityChanged)
		XCTAssertEqual(
			defaults.string(forKey: "cloudkit.lastKnownUserRecordName"),
			"USER-A"
		)
		await tracker.acknowledgeIdentityChange()
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
		let outcome = await tracker.handleAccountChange(client: client)
		XCTAssertTrue(client.didReset)
		XCTAssertEqual(outcome, .identityChanged)
		XCTAssertEqual(
			defaults.string(forKey: "cloudkit.lastKnownUserRecordName"),
			"USER-A"
		)
		await tracker.acknowledgeIdentityChange()
		XCTAssertNil(defaults.string(forKey: "cloudkit.lastKnownUserRecordName"))
	}

	func testUnacknowledgedIdentityChangeIsRetried() async {
		defaults.set("USER-A", forKey: "cloudkit.lastKnownUserRecordName")
		let client = SpyClient()
		let tracker = AccountIdentityTracker(
			defaults: defaults,
			currentUserRecordID: { CKRecord.ID(recordName: "USER-B") },
			tokensExist: { true }
		)

		let first = await tracker.handleAccountChange(client: client)
		let retry = await tracker.handleAccountChange(client: client)

		XCTAssertEqual(first, .identityChanged)
		XCTAssertEqual(retry, .identityChanged)
		XCTAssertEqual(client.resetCount, 2)
		XCTAssertEqual(
			defaults.string(forKey: "cloudkit.lastKnownUserRecordName"),
			"USER-A"
		)
		await tracker.acknowledgeIdentityChange()
		let acknowledged = await tracker.handleAccountChange(client: client)
		XCTAssertEqual(acknowledged, .unchanged)
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
		XCTAssertTrue(client.didDeleteSubscription)
		XCTAssertTrue(client.didDeleteSnippetSubscription)
	}

	func testTemporaryIdentityFailurePreservesPriorAccountState() async {
		defaults.set("USER-A", forKey: "cloudkit.lastKnownUserRecordName")
		let client = SpyClient()
		let tracker = AccountIdentityTracker(
			defaults: defaults,
			currentIdentity: { .temporarilyUnavailable("network unavailable") },
			tokensExist: { true }
		)

		let outcome = await tracker.handleAccountChange(client: client)

		XCTAssertEqual(outcome, .temporarilyUnavailable("network unavailable"))
		XCTAssertFalse(client.didReset)
		XCTAssertFalse(client.didDeleteSubscription)
		XCTAssertEqual(
			defaults.string(forKey: "cloudkit.lastKnownUserRecordName"),
			"USER-A"
		)
	}

	// Test-only spy; per-test instance, never accessed concurrently.
	private final class SpyClient: AccountSensitiveClient {
		nonisolated(unsafe) var didReset = false
		nonisolated(unsafe) var resetCount = 0
		nonisolated(unsafe) var didDeleteSubscription = false
		nonisolated(unsafe) var didResetSnippet = false
		nonisolated(unsafe) var didDeleteSnippetSubscription = false
		func resetHostSyncState() async {
			didReset = true
			resetCount += 1
		}
		func deleteHostSubscription() async throws { didDeleteSubscription = true }
		func resetSnippetSyncState() async { didResetSnippet = true }
		func deleteSnippetSubscription() async throws { didDeleteSnippetSubscription = true }
	}
}
