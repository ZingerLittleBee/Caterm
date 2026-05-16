import CloudKit
import XCTest
@testable import CloudKitSyncClient
@testable import ServerSyncClient
@testable import SSHCommandBuilder

final class CKRecordHostMappingIconTests: XCTestCase {
	private let zoneID = CKRecordZone.ID(zoneName: "Caterm")

	func test_makeRecord_writesIconWhenPresent() throws {
		let input = RemoteHostCreateInput(
			name: "h", hostname: "h.example", port: 22, username: "u",
			icon: "server.rack"
		)
		let rec = CKRecordHostMapping.makeRecord(
			recordName: "rec", zoneID: zoneID, input: input
		)
		XCTAssertEqual(rec["icon"] as? String, "server.rack")
	}

	func test_makeRecord_omitsIconWhenNil() throws {
		let input = RemoteHostCreateInput(
			name: "h", hostname: "h.example", port: 22, username: "u"
		)
		let rec = CKRecordHostMapping.makeRecord(
			recordName: "rec", zoneID: zoneID, input: input
		)
		XCTAssertNil(rec["icon"])
	}

	func test_applyMetadata_setsAndClearsIcon() throws {
		let rec = CKRecord(recordType: "Host",
		                   recordID: .init(recordName: "rec", zoneID: zoneID))
		var host = SSHHost(
			id: UUID(), serverId: "rec",
			name: "h", hostname: "h.example", port: 22,
			username: "u", credential: .password,
			updatedAt: Date(timeIntervalSince1970: 2000)
		)
		host.icon = "globe.americas.fill"
		CKRecordHostMapping.applyMetadata(into: rec, from: host)
		XCTAssertEqual(rec["icon"] as? String, "globe.americas.fill")

		// Clearing the icon on a later edit must remove it from the record so
		// other devices pull `nil` rather than a stale symbol.
		host.icon = nil
		CKRecordHostMapping.applyMetadata(into: rec, from: host)
		XCTAssertNil(rec["icon"])
	}

	func test_decode_readsIcon() throws {
		let rec = CKRecord(recordType: "Host",
		                   recordID: .init(recordName: "rec", zoneID: zoneID))
		rec["name"] = "h" as CKRecordValue
		rec["hostname"] = "h.example" as CKRecordValue
		rec["port"] = 22 as CKRecordValue
		rec["username"] = "u" as CKRecordValue
		rec["authType"] = "key" as CKRecordValue
		rec["metadataUpdatedAt"] = Date() as CKRecordValue
		rec["icon"] = "flag.fill" as CKRecordValue
		let result = try CKRecordHostMapping.decode(rec)
		XCTAssertEqual(result.host.icon, "flag.fill")
	}

	func test_decode_absentIconIsNil() throws {
		let rec = CKRecord(recordType: "Host",
		                   recordID: .init(recordName: "rec", zoneID: zoneID))
		rec["name"] = "h" as CKRecordValue
		rec["hostname"] = "h.example" as CKRecordValue
		rec["port"] = 22 as CKRecordValue
		rec["username"] = "u" as CKRecordValue
		rec["authType"] = "key" as CKRecordValue
		rec["metadataUpdatedAt"] = Date() as CKRecordValue
		let result = try CKRecordHostMapping.decode(rec)
		XCTAssertNil(result.host.icon)
	}
}
