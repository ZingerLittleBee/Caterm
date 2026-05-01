import CloudKit
import Foundation
@testable import CloudKitSyncClient

/// Test double for `CKDatabaseProtocol`. Stores records in an in-memory
/// dictionary keyed by recordName. Per-method error knobs let tests
/// exercise both happy paths and CKError surfacing.
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

    func records(matching query: CKQuery,
                 inZoneWith zoneID: CKRecordZone.ID?,
                 desiredKeys: [CKRecord.FieldKey]?,
                 resultsLimit: Int)
        async throws -> (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)],
                         queryCursor: CKQueryOperation.Cursor?)
    {
        recordsCallCount += 1
        if let err = recordsError { throw err }
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
        records.removeValue(forKey: recordID)
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
        savedZones[zone.zoneID] = zone
        return zone
    }
}
