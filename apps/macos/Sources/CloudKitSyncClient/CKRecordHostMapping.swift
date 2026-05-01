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

	public enum DecodeError: Error, Equatable {
		case missingField(String)
	}

	public static func decode(_ rec: CKRecord) throws -> RemoteHost {
		guard let name = rec["name"] as? String else { throw DecodeError.missingField("name") }
		guard let hostname = rec["hostname"] as? String else { throw DecodeError.missingField("hostname") }
		guard let port = rec["port"] as? Int else { throw DecodeError.missingField("port") }
		guard let username = rec["username"] as? String else { throw DecodeError.missingField("username") }
		let authType = (rec["authType"] as? String) ?? "key"
		return RemoteHost(
			id: rec.recordID.recordName,
			name: name,
			hostname: hostname,
			port: port,
			username: username,
			authType: authType,
			createdAt: rec.creationDate ?? .distantPast,
			updatedAt: rec.modificationDate ?? .distantPast
		)
	}
}
