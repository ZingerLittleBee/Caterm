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

	func fetchDatabaseChanges(previousServerChangeToken: CKServerChangeToken?)
		async throws -> (changedZoneIDs: [CKRecordZone.ID],
		                 deletedZoneIDs: [CKRecordZone.ID],
		                 purgedZoneIDs: [CKRecordZone.ID],
		                 encryptedDataResetZoneIDs: [CKRecordZone.ID],
		                 newToken: CKServerChangeToken?,
		                 moreComing: Bool)

	func fetchZoneChanges(zoneID: CKRecordZone.ID,
	                      previousServerChangeToken: CKServerChangeToken?)
		async throws -> (changedRecords: [CKRecord],
		                 deletedRecords: [(CKRecord.ID, CKRecord.RecordType)],
		                 newToken: CKServerChangeToken?,
		                 moreComing: Bool)

	func saveSubscription(_ subscription: CKSubscription)
		async throws -> CKSubscription
	func deleteSubscription(withID id: CKSubscription.ID)
		async throws -> CKSubscription.ID
}

extension CKDatabase: CKDatabaseProtocol {}

extension CKDatabase {
	public func fetchDatabaseChanges(previousServerChangeToken: CKServerChangeToken?)
		async throws -> (changedZoneIDs: [CKRecordZone.ID],
		                 deletedZoneIDs: [CKRecordZone.ID],
		                 purgedZoneIDs: [CKRecordZone.ID],
		                 encryptedDataResetZoneIDs: [CKRecordZone.ID],
		                 newToken: CKServerChangeToken?,
		                 moreComing: Bool) {
		try await withCheckedThrowingContinuation { cont in
			let op = CKFetchDatabaseChangesOperation(
				previousServerChangeToken: previousServerChangeToken
			)
			var changed: [CKRecordZone.ID] = []
			var deleted: [CKRecordZone.ID] = []
			var purged: [CKRecordZone.ID] = []
			var encReset: [CKRecordZone.ID] = []
			var newToken: CKServerChangeToken?
			var more = false
			op.recordZoneWithIDChangedBlock = { changed.append($0) }
			op.recordZoneWithIDWasDeletedBlock = { deleted.append($0) }
			op.recordZoneWithIDWasPurgedBlock = { purged.append($0) }
			op.recordZoneWithIDWasDeletedDueToUserEncryptedDataResetBlock = {
				encReset.append($0)
			}
			op.changeTokenUpdatedBlock = { newToken = $0 }
			op.fetchDatabaseChangesResultBlock = { result in
				switch result {
				case .success(let info):
					newToken = info.serverChangeToken
					more = info.moreComing
					cont.resume(returning: (changed, deleted, purged, encReset,
					                        newToken, more))
				case .failure(let err):
					cont.resume(throwing: err)
				}
			}
			self.add(op)
		}
	}

	public func fetchZoneChanges(zoneID: CKRecordZone.ID,
	                             previousServerChangeToken: CKServerChangeToken?)
		async throws -> (changedRecords: [CKRecord],
		                 deletedRecords: [(CKRecord.ID, CKRecord.RecordType)],
		                 newToken: CKServerChangeToken?,
		                 moreComing: Bool) {
		try await withCheckedThrowingContinuation { cont in
			let cfg = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
				previousServerChangeToken: previousServerChangeToken,
				resultsLimit: nil,
				desiredKeys: nil
			)
			let op = CKFetchRecordZoneChangesOperation(
				recordZoneIDs: [zoneID],
				configurationsByRecordZoneID: [zoneID: cfg]
			)
			var changed: [CKRecord] = []
			var deleted: [(CKRecord.ID, CKRecord.RecordType)] = []
			var newToken: CKServerChangeToken?
			var more = false
			op.recordWasChangedBlock = { _, result in
				if case .success(let rec) = result { changed.append(rec) }
			}
			op.recordWithIDWasDeletedBlock = { id, rt in deleted.append((id, rt)) }
			op.recordZoneFetchResultBlock = { _, result in
				if case .success(let info) = result {
					newToken = info.serverChangeToken
					more = info.moreComing
				}
			}
			op.fetchRecordZoneChangesResultBlock = { result in
				switch result {
				case .success:
					cont.resume(returning: (changed, deleted, newToken, more))
				case .failure(let err):
					cont.resume(throwing: err)
				}
			}
			self.add(op)
		}
	}

	public func saveSubscription(_ subscription: CKSubscription)
		async throws -> CKSubscription {
		try await save(subscription)
	}
}
