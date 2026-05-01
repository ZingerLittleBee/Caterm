import CloudKit
import Foundation
@testable import CloudKitSyncClient

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
}
