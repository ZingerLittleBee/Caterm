import CloudKit
import Foundation

/// The minimal `CKDatabase` surface CloudKitSyncClient needs.
///
/// Wrapping the API (rather than calling `CKDatabase` methods directly) lets
/// us inject `FakeCloudDatabase` in unit tests. Apple's `CKDatabase` is a
/// concrete `NSObject` subclass that cannot be subclassed meaningfully —
/// every async API on it is a free function bound to the instance.
///
/// Method shapes mirror the `async` overloads added in iOS 15 / macOS 12.
public protocol CKDatabaseProtocol: Sendable {
    func records(matching query: CKQuery,
                 inZoneWith zoneID: CKRecordZone.ID?,
                 desiredKeys: [CKRecord.FieldKey]?,
                 resultsLimit: Int)
        async throws -> (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)],
                         queryCursor: CKQueryOperation.Cursor?)

    func save(_ record: CKRecord) async throws -> CKRecord
    func deleteRecord(withID recordID: CKRecord.ID) async throws -> CKRecord.ID
    func record(for recordID: CKRecord.ID) async throws -> CKRecord
    func save(_ zone: CKRecordZone) async throws -> CKRecordZone
}

extension CKDatabase: CKDatabaseProtocol {}
