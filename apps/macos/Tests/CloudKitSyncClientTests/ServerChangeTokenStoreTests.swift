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

final class InMemoryServerChangeTokenStoreTests: XCTestCase {
	func testCommitTokensApplied() async throws {
		let store = InMemoryServerChangeTokenStore()
		let epoch = await store.currentEpoch()
		let outcome = await store.commitTokens(
			expectedEpoch: epoch,
			db: TokenCAS(prev: nil, new: Data([1, 2, 3])),
			zones: [:]
		)
		XCTAssertEqual(outcome, .applied)
		let stored = await store.loadDatabaseToken()
		XCTAssertEqual(stored?.archivedData, Data([1, 2, 3]))
	}

	func testCommitTokensStaleEpoch() async throws {
		let store = InMemoryServerChangeTokenStore()
		let staleEpoch = await store.currentEpoch()
		await store.bumpEpoch()
		let outcome = await store.commitTokens(
			expectedEpoch: staleEpoch,
			db: TokenCAS(prev: nil, new: Data([1])),
			zones: [:]
		)
		XCTAssertEqual(outcome, .staleEpoch)
		let stored = await store.loadDatabaseToken()
		XCTAssertNil(stored, "stale-epoch commit must not write")
	}

	func testCommitTokensPartialCASOnDb() async throws {
		let store = InMemoryServerChangeTokenStore()
		let epoch = await store.currentEpoch()
		// Pre-seed a token by an earlier successful commit.
		_ = await store.commitTokens(
			expectedEpoch: epoch,
			db: TokenCAS(prev: nil, new: Data([1])),
			zones: [:]
		)
		// Try to commit assuming prev was nil — but persisted is now Data([1]).
		let outcome = await store.commitTokens(
			expectedEpoch: epoch,
			db: TokenCAS(prev: nil, new: Data([2])),
			zones: [:]
		)
		XCTAssertEqual(outcome, .partialCAS(skippedZoneKeys: [], skippedDb: true))
		let stored = await store.loadDatabaseToken()
		XCTAssertEqual(stored?.archivedData, Data([1]))
	}

	func testClearAllBumpsEpochAndDeletesKeys() async throws {
		let store = InMemoryServerChangeTokenStore()
		let epoch0 = await store.currentEpoch()
		_ = await store.commitTokens(
			expectedEpoch: epoch0,
			db: TokenCAS(prev: nil, new: Data([1])),
			zones: ["Z": TokenCAS(prev: nil, new: Data([2]))]
		)
		await store.clearAll()
		let epoch1 = await store.currentEpoch()
		XCTAssertEqual(epoch1, epoch0 + 1)
		let db = await store.loadDatabaseToken()
		XCTAssertNil(db)
		let zone = await store.loadZoneToken(CKRecordZone.ID(zoneName: "Z"))
		XCTAssertNil(zone)
	}
}

final class UserDefaultsServerChangeTokenStoreTests: XCTestCase {
	private var defaults: UserDefaults!
	private var suiteName: String!

	override func setUp() async throws {
		suiteName = "UserDefaultsServerChangeTokenStoreTests.\(UUID().uuidString)"
		defaults = UserDefaults(suiteName: suiteName)
	}

	override func tearDown() async throws {
		UserDefaults.standard.removePersistentDomain(forName: suiteName)
		defaults = nil
		suiteName = nil
	}

	func testRoundTripPersistsAcrossInstances() async throws {
		let s1 = UserDefaultsServerChangeTokenStore(defaults: defaults)
		let epoch = await s1.currentEpoch()
		_ = await s1.commitTokens(
			expectedEpoch: epoch,
			db: TokenCAS(prev: nil, new: Data([9, 9, 9])),
			zones: [:]
		)
		// New instance reading the same defaults backing
		let s2 = UserDefaultsServerChangeTokenStore(defaults: defaults)
		let token = await s2.loadDatabaseToken()
		XCTAssertEqual(token?.archivedData, Data([9, 9, 9]))
	}

	func testCorruptStoredBytesAreReturnedAsIsForCAS() async throws {
		// Pre-seed garbage directly via UserDefaults; loadDatabaseToken
		// must NOT decode synchronously, so it returns the bytes wrapped.
		defaults.set(Data([0xDE, 0xAD]), forKey: "cloudkit.changeToken.database")
		let s = UserDefaultsServerChangeTokenStore(defaults: defaults)
		let token = await s.loadDatabaseToken()
		XCTAssertEqual(token?.archivedData, Data([0xDE, 0xAD]))
		XCTAssertThrowsError(try token?.unarchive())
	}

	func testEpochSurvivesAcrossInstances() async throws {
		let s1 = UserDefaultsServerChangeTokenStore(defaults: defaults)
		await s1.bumpEpoch()
		await s1.bumpEpoch()
		let s2 = UserDefaultsServerChangeTokenStore(defaults: defaults)
		let epoch = await s2.currentEpoch()
		XCTAssertEqual(epoch, 2)
	}
}
