import CloudKit
import ServerSyncClient
import XCTest
@testable import CloudKitSyncClient

final class CKRecordHostMappingTests: XCTestCase {
	private let zoneID = CKRecordZone.ID(zoneName: "Caterm")

	func testEncodeCreateInputProducesRecordWithFields() {
		let input = RemoteHostCreateInput(
			name: "alpha", hostname: "x.example.com", port: 2222, username: "u"
		)
		let recordName = "abc-123"
		let rec = CKRecordHostMapping.makeRecord(
			recordName: recordName, zoneID: zoneID, input: input
		)
		XCTAssertEqual(rec.recordType, "Host")
		XCTAssertEqual(rec.recordID.recordName, recordName)
		XCTAssertEqual(rec.recordID.zoneID, zoneID)
		XCTAssertEqual(rec["name"] as? String, "alpha")
		XCTAssertEqual(rec["hostname"] as? String, "x.example.com")
		XCTAssertEqual(rec["port"] as? Int, 2222)
		XCTAssertEqual(rec["username"] as? String, "u")
		XCTAssertEqual(rec["authType"] as? String, "key")
	}

	func testDecodeRecordWithAllFieldsProducesRemoteHost() throws {
		let recID = CKRecord.ID(recordName: "rec-1", zoneID: zoneID)
		let rec = CKRecord(recordType: "Host", recordID: recID)
		rec["name"] = "alpha" as CKRecordValue
		rec["hostname"] = "x" as CKRecordValue
		rec["port"] = 22 as CKRecordValue
		rec["username"] = "u" as CKRecordValue
		rec["authType"] = "key" as CKRecordValue
		// creationDate/modificationDate are normally set by the server.
		// Local CKRecord starts with nil — we reflect that via mapping
		// fallback to Date.distantPast so reconciler treats unsynced as
		// older than any real remote record.

		let host = try CKRecordHostMapping.decode(rec)
		XCTAssertEqual(host.id, "rec-1")
		XCTAssertEqual(host.name, "alpha")
		XCTAssertEqual(host.hostname, "x")
		XCTAssertEqual(host.port, 22)
		XCTAssertEqual(host.username, "u")
		XCTAssertEqual(host.authType, "key")
		XCTAssertEqual(host.createdAt, .distantPast)
		XCTAssertEqual(host.updatedAt, .distantPast)
	}

	func testDecodeMissingHostnameThrows() {
		let recID = CKRecord.ID(recordName: "rec-bad", zoneID: zoneID)
		let rec = CKRecord(recordType: "Host", recordID: recID)
		rec["name"] = "x" as CKRecordValue
		// hostname intentionally omitted
		rec["port"] = 22 as CKRecordValue
		rec["username"] = "u" as CKRecordValue
		XCTAssertThrowsError(try CKRecordHostMapping.decode(rec)) { error in
			XCTAssertEqual(error as? CKRecordHostMapping.DecodeError,
						   .missingField("hostname"))
		}
	}
}
