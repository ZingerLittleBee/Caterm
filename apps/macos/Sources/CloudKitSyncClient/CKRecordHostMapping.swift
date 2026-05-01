import CloudKit
import Foundation
import ServerSyncClient

public enum CKRecordHostMapping {
	public static let recordType: CKRecord.RecordType = "Host"

	public static func makeRecord(recordName: String,
	                              zoneID: CKRecordZone.ID,
	                              input: RemoteHostCreateInput) -> CKRecord {
		let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
		let rec = CKRecord(recordType: recordType, recordID: id)
		rec["name"] = input.name as CKRecordValue
		rec["hostname"] = input.hostname as CKRecordValue
		rec["port"] = input.port as CKRecordValue
		rec["username"] = input.username as CKRecordValue
		rec["authType"] = input.authType as CKRecordValue
		return rec
	}
}
