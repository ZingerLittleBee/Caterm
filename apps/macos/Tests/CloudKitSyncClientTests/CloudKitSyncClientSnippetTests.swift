import CloudKit
import XCTest
import SnippetSyncClient
@testable import CloudKitSyncClient

// MARK: - CloudKitSyncClient snippet push/delete/subscription tests

final class CloudKitSyncClientSnippetTests: XCTestCase {
	func test_pushSnippet_savesToSnippetsZone() async throws {
		let fakeDB = FakeCloudDatabase()
		let client = CloudKitSyncClient(
			database: fakeDB,
			zoneID: CKRecordZone.ID(zoneName: "Caterm", ownerName: CKCurrentUserDefaultName)
		)
		let s = Snippet(id: UUID(), name: "n", content: "c",
		                createdAt: .now, updatedAt: .now)
		_ = try await client.pushSnippet(s)
		let saved = try XCTUnwrap(fakeDB.savedRecords.last)
		XCTAssertEqual(saved.recordID.zoneID.zoneName,
		               CloudKitPushNames.snippetZoneName,
		               "Snippets must land in the Snippets zone, not the Caterm host zone")
	}

	func test_deleteSnippet_callsDeleteWithSnippetZoneID() async throws {
		let fakeDB = FakeCloudDatabase()
		let client = CloudKitSyncClient(
			database: fakeDB,
			zoneID: CKRecordZone.ID(zoneName: "Caterm", ownerName: CKCurrentUserDefaultName)
		)
		let id = UUID()
		try await client.deleteSnippet(id: id)
		let deleted = try XCTUnwrap(fakeDB.deletedRecordIDs.last)
		XCTAssertEqual(deleted.recordName, id.uuidString)
		XCTAssertEqual(deleted.zoneID.zoneName, CloudKitPushNames.snippetZoneName)
	}

	func test_ensureSnippetSubscription_isIdempotent() async throws {
		let fakeDB = FakeCloudDatabase()
		let client = CloudKitSyncClient(
			database: fakeDB,
			zoneID: CKRecordZone.ID(zoneName: "Caterm", ownerName: CKCurrentUserDefaultName)
		)
		try await client.ensureSnippetSubscription()
		try await client.ensureSnippetSubscription()
		// Both calls must succeed and each must have saved a subscription.
		XCTAssertEqual(fakeDB.savedSubscriptionIDs.filter {
			$0 == CloudKitPushNames.snippetSubscriptionID
		}.count, 2)
	}
}

// MARK: - CKRecordSnippetMapping encode/decode tests

final class CKRecordSnippetMappingTests: XCTestCase {
	func test_encode_setsAllFields() {
		let id = UUID()
		let s = Snippet(
			id: id, name: "n", content: "c",
			placeholders: nil,
			createdAt: Date(timeIntervalSince1970: 1),
			updatedAt: Date(timeIntervalSince1970: 2),
			serverId: nil, revision: 7, metadataUpdatedAt: nil
		)
		let zoneID = CKRecordZone.ID(zoneName: "Snippets",
		                             ownerName: CKCurrentUserDefaultName)
		let rec = CKRecordSnippetMapping.encode(s, zoneID: zoneID)
		XCTAssertEqual(rec.recordID.recordName, id.uuidString)
		XCTAssertEqual(rec.recordID.zoneID, zoneID)
		XCTAssertEqual(rec["name"] as? String, "n")
		XCTAssertEqual(rec["content"] as? String, "c")
		XCTAssertEqual(rec["createdAt"] as? Date, Date(timeIntervalSince1970: 1))
		XCTAssertEqual(rec["updatedAt"] as? Date, Date(timeIntervalSince1970: 2))
		XCTAssertEqual(rec["revision"] as? Int64, 7)
		XCTAssertEqual(rec["schemaVersion"] as? Int64, 1)
		XCTAssertNil(rec["placeholders"])
	}

	func test_decode_roundTripsCoreFields() throws {
		let id = UUID()
		let zoneID = CKRecordZone.ID(zoneName: "Snippets",
		                             ownerName: CKCurrentUserDefaultName)
		let recID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
		let rec = CKRecord(recordType: "Snippet", recordID: recID)
		rec["name"] = "n" as CKRecordValue
		rec["content"] = "c" as CKRecordValue
		rec["createdAt"] = Date(timeIntervalSince1970: 1) as CKRecordValue
		rec["updatedAt"] = Date(timeIntervalSince1970: 2) as CKRecordValue
		rec["revision"] = Int64(7) as CKRecordValue
		rec["schemaVersion"] = Int64(1) as CKRecordValue

		let decoded = try CKRecordSnippetMapping.decode(rec)
		XCTAssertEqual(decoded.id, id)
		XCTAssertEqual(decoded.name, "n")
		XCTAssertEqual(decoded.content, "c")
		XCTAssertEqual(decoded.revision, 7)
		XCTAssertEqual(decoded.serverId, id.uuidString)
		XCTAssertNil(decoded.placeholders)
	}

	func test_decode_missingRequiredField_throws() {
		let zoneID = CKRecordZone.ID(zoneName: "Snippets",
		                             ownerName: CKCurrentUserDefaultName)
		let recID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
		let rec = CKRecord(recordType: "Snippet", recordID: recID)
		rec["name"] = "n" as CKRecordValue
		// content is missing
		XCTAssertThrowsError(try CKRecordSnippetMapping.decode(rec))
	}

	func test_placeholders_roundTripJSONEncoded() throws {
		let zoneID = CKRecordZone.ID(zoneName: "Snippets",
		                             ownerName: CKCurrentUserDefaultName)
		let s = Snippet(id: UUID(), name: "n", content: "c",
		                placeholders: ["path", "user"],
		                createdAt: .now, updatedAt: .now)
		let rec = CKRecordSnippetMapping.encode(s, zoneID: zoneID)
		let decoded = try CKRecordSnippetMapping.decode(rec)
		XCTAssertEqual(decoded.placeholders, ["path", "user"])
	}
}
