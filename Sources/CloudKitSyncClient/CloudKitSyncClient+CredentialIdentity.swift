import CloudKit
import CredentialIdentityStore
import Foundation
import ServerSyncClient

extension CloudKitSyncClient: CredentialIdentitySyncClient {
	public func listCredentialIdentities() async throws
		-> [CredentialIdentitySyncRecord] {
		let query = CKQuery(
			recordType: CKRecordCredentialIdentityMapping.recordType,
			predicate: NSPredicate(value: true)
		)
		do {
			let (matches, _) = try await database.records(
				matching: query,
				inZoneWith: zoneID,
				desiredKeys: nil,
				resultsLimit: CKQueryOperation.maximumResults
			)
			return matches.compactMap { _, result in
				guard case .success(let record) = result else {
					return nil
				}
				return try? CKRecordCredentialIdentityMapping.decode(record)
			}
		} catch let error as CKError where error.code == .zoneNotFound {
			return []
		} catch {
			throw CloudKitErrorMapping.map(error)
		}
	}

	public func upsertCredentialIdentity(
		_ record: CredentialIdentitySyncRecord
	) async throws -> String {
		do {
			try await ensureZoneForIdentitySync()
			let recordID = CKRecord.ID(
				recordName: record.identity.id.uuidString,
				zoneID: zoneID
			)
			var cloudRecord: CKRecord
			do {
				cloudRecord = try await database.record(for: recordID)
				try CKRecordCredentialIdentityMapping.apply(
					record,
					to: cloudRecord
				)
			} catch let error as CKError where error.code == .unknownItem {
				cloudRecord = try CKRecordCredentialIdentityMapping.makeRecord(
					record: record,
					zoneID: zoneID
				)
			}
			let saved = try await database.save(cloudRecord)
			return saved.recordID.recordName
		} catch {
			throw CloudKitErrorMapping.map(error)
		}
	}

	public func deleteCredentialIdentity(id: String) async throws {
		let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
		do {
			_ = try await database.deleteRecord(withID: recordID)
		} catch let error as CKError where error.code == .unknownItem {
			return
		} catch {
			throw CloudKitErrorMapping.map(error)
		}
	}

	private func ensureZoneForIdentitySync() async throws {
		_ = try await database.save(CKRecordZone(zoneID: zoneID))
	}
}
