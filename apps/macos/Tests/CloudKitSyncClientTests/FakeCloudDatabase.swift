import CloudKit
import Foundation
@testable import CloudKitSyncClient

struct DatabaseChangesScript {
	var changedZoneIDs: [CKRecordZone.ID] = []
	var deletedZoneIDs: [CKRecordZone.ID] = []
	var purgedZoneIDs: [CKRecordZone.ID] = []
	var encryptedDataResetZoneIDs: [CKRecordZone.ID] = []
	var newToken: CKServerChangeToken?
	var moreComing: Bool = false
	var error: Error?
}

struct ZoneChangesScript {
	var changedRecords: [CKRecord] = []
	var deletedRecords: [(CKRecord.ID, CKRecord.RecordType)] = []
	var newToken: CKServerChangeToken?
	var moreComing: Bool = false
	var error: Error?
}

/// Test double for `CKDatabaseProtocol`. Stores records in an in-memory
/// dictionary keyed by recordName. Per-method error knobs let tests
/// exercise both happy paths and CKError surfacing.
// @unchecked Sendable: mutable state accessed only from the XCTest serial
// executor. If this double is ever used from a concurrent test harness,
// replace the stored properties with actors or locks.
final class FakeCloudDatabase: CKDatabaseProtocol, @unchecked Sendable {
	var records: [CKRecord.ID: CKRecord] = [:]
	var savedZones: [CKRecordZone.ID: CKRecordZone] = [:]

	var recordsCallCount = 0
	var saveCallCount = 0
	var deleteCallCount = 0
	var recordFetchCallCount = 0
	var saveZoneCallCount = 0

	var recordsError: Error?
	var saveError: Error?
	var deleteError: Error?
	var recordFetchError: Error?
	var saveZoneError: Error?

	private var databaseChangesQueue: [DatabaseChangesScript] = []
	private var zoneChangesQueue: [CKRecordZone.ID: [ZoneChangesScript]] = [:]
	private(set) var savedSubscriptions: [CKSubscription] = []
	private(set) var deletedSubscriptionIDs: [CKSubscription.ID] = []
	var saveSubscriptionError: Error?
	var deleteSubscriptionError: Error?

	func enqueueDatabaseChanges(_ script: DatabaseChangesScript) {
		databaseChangesQueue.append(script)
	}

	func enqueueZoneChanges(_ zoneID: CKRecordZone.ID, _ script: ZoneChangesScript) {
		zoneChangesQueue[zoneID, default: []].append(script)
	}

	/// Helper: produces a CKServerChangeToken via NSKeyedUnarchiver replay of a
	/// pre-captured byte sequence. CKServerChangeToken has no public init; this
	/// is the only portable way to obtain one in unit tests. If the byte fixture
	/// is rejected by NSKeyedUnarchiver on a given toolchain, callers should
	/// XCTSkip and rely on integration tests for end-to-end coverage.
	static func makeRealishToken() throws -> CKServerChangeToken {
		let bytes = Data(base64Encoded:
			"YnBsaXN0MDDUAQIDBAUGBwhYJHZlcnNpb25YJG9iamVjdHNZJGFyY2hpdmVyVCR0b3AS"
			+ "AAGGoKMJChJVJG51bGzSCwwNDl8QF0NLU2VydmVyQ2hhbmdlVG9rZW4tZmFrZQAAAAAA"
			+ "AAAAAAAAAA=="
		)!
		if let t = try NSKeyedUnarchiver.unarchivedObject(
			ofClass: CKServerChangeToken.self, from: bytes
		) {
			return t
		}
		throw NSError(domain: "FakeCloudDatabase", code: 1,
		              userInfo: [NSLocalizedDescriptionKey: "could not synthesize CKServerChangeToken from fixture bytes"])
	}

	// MARK: - CKDatabaseProtocol

	func records(matching query: CKQuery,
	             inZoneWith zoneID: CKRecordZone.ID?,
	             desiredKeys: [CKRecord.FieldKey]?,
	             resultsLimit: Int)
		async throws -> (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)],
		                 queryCursor: CKQueryOperation.Cursor?)
	{
		recordsCallCount += 1
		if let err = recordsError { throw err }
		// resultsLimit intentionally ignored — tests use small fixtures and never
		// exercise pagination. Add a paginating fake if that ever changes.
		let filtered = records.values.filter { $0.recordType == query.recordType }
		let pairs = filtered.map { rec in
			(rec.recordID, Result<CKRecord, Error>.success(rec))
		}
		return (pairs, nil)
	}

	func save(_ record: CKRecord) async throws -> CKRecord {
		saveCallCount += 1
		if let err = saveError { throw err }
		records[record.recordID] = record
		return record
	}

	func deleteRecord(withID recordID: CKRecord.ID) async throws -> CKRecord.ID {
		deleteCallCount += 1
		if let err = deleteError { throw err }
		guard records.removeValue(forKey: recordID) != nil else {
			// Match real CKDatabase semantics: deleting a missing id throws.
			throw CKError(.unknownItem)
		}
		return recordID
	}

	func record(for recordID: CKRecord.ID) async throws -> CKRecord {
		recordFetchCallCount += 1
		if let err = recordFetchError { throw err }
		guard let r = records[recordID] else {
			throw CKError(.unknownItem)
		}
		return r
	}

	func save(_ zone: CKRecordZone) async throws -> CKRecordZone {
		saveZoneCallCount += 1
		if let err = saveZoneError { throw err }
		savedZones[zone.zoneID] = zone
		return zone
	}

	func fetchDatabaseChanges(previousServerChangeToken: CKServerChangeToken?)
		async throws -> (changedZoneIDs: [CKRecordZone.ID],
		                  deletedZoneIDs: [CKRecordZone.ID],
		                  purgedZoneIDs: [CKRecordZone.ID],
		                  encryptedDataResetZoneIDs: [CKRecordZone.ID],
		                  newToken: CKServerChangeToken?,
		                  moreComing: Bool) {
		guard !databaseChangesQueue.isEmpty else {
			return ([], [], [], [], nil, false)
		}
		let s = databaseChangesQueue.removeFirst()
		if let err = s.error { throw err }
		return (s.changedZoneIDs, s.deletedZoneIDs, s.purgedZoneIDs,
		        s.encryptedDataResetZoneIDs, s.newToken, s.moreComing)
	}

	func fetchZoneChanges(zoneID: CKRecordZone.ID,
	                      previousServerChangeToken: CKServerChangeToken?)
		async throws -> (changedRecords: [CKRecord],
		                  deletedRecords: [(CKRecord.ID, CKRecord.RecordType)],
		                  newToken: CKServerChangeToken?,
		                  moreComing: Bool) {
		guard var queue = zoneChangesQueue[zoneID], !queue.isEmpty else {
			return ([], [], nil, false)
		}
		let s = queue.removeFirst()
		zoneChangesQueue[zoneID] = queue
		if let err = s.error { throw err }
		return (s.changedRecords, s.deletedRecords, s.newToken, s.moreComing)
	}

	func saveSubscription(_ subscription: CKSubscription) async throws -> CKSubscription {
		if let err = saveSubscriptionError { throw err }
		savedSubscriptions.append(subscription)
		return subscription
	}

	func deleteSubscription(withID id: CKSubscription.ID) async throws -> CKSubscription.ID {
		if let err = deleteSubscriptionError { throw err }
		deletedSubscriptionIDs.append(id)
		return id
	}
}
