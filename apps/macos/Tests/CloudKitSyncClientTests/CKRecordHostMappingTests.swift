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
}
