import CloudKit
import Foundation
import SnippetSyncClient

public enum CKRecordSnippetMappingError: Error, Equatable {
	case missingRequiredField(String)
	case invalidUUID(String)
	case placeholdersDecodeFailure
}

public enum CKRecordSnippetMapping {
	public static let recordType = "Snippet"
	public static let schemaVersion: Int64 = 1

	public static func encode(_ s: Snippet, zoneID: CKRecordZone.ID) -> CKRecord {
		let recID = CKRecord.ID(recordName: s.id.uuidString, zoneID: zoneID)
		let rec = CKRecord(recordType: recordType, recordID: recID)
		rec["name"] = s.name as CKRecordValue
		rec["content"] = s.content as CKRecordValue
		rec["createdAt"] = s.createdAt as CKRecordValue
		rec["updatedAt"] = s.updatedAt as CKRecordValue
		rec["revision"] = Int64(s.revision) as CKRecordValue
		rec["schemaVersion"] = Self.schemaVersion as CKRecordValue
		if let placeholders = s.placeholders,
		   let data = try? JSONEncoder().encode(placeholders),
		   let json = String(data: data, encoding: .utf8) {
			rec["placeholders"] = json as CKRecordValue
		}
		return rec
	}

	public static func decode(_ rec: CKRecord) throws -> Snippet {
		guard let id = UUID(uuidString: rec.recordID.recordName) else {
			throw CKRecordSnippetMappingError.invalidUUID(rec.recordID.recordName)
		}
		guard let name = rec["name"] as? String else {
			throw CKRecordSnippetMappingError.missingRequiredField("name")
		}
		guard let content = rec["content"] as? String else {
			throw CKRecordSnippetMappingError.missingRequiredField("content")
		}
		guard let createdAt = rec["createdAt"] as? Date else {
			throw CKRecordSnippetMappingError.missingRequiredField("createdAt")
		}
		guard let updatedAt = rec["updatedAt"] as? Date else {
			throw CKRecordSnippetMappingError.missingRequiredField("updatedAt")
		}
		let revision = (rec["revision"] as? Int64).map(Int.init) ?? 0
		var placeholders: [String]?
		if let json = rec["placeholders"] as? String,
		   let data = json.data(using: .utf8) {
			do {
				placeholders = try JSONDecoder().decode([String].self, from: data)
			} catch {
				throw CKRecordSnippetMappingError.placeholdersDecodeFailure
			}
		}
		return Snippet(
			id: id,
			name: name,
			content: content,
			placeholders: placeholders,
			createdAt: createdAt,
			updatedAt: updatedAt,
			serverId: rec.recordID.recordName,
			revision: revision,
			metadataUpdatedAt: rec.modificationDate
		)
	}
}
