import CloudKit
import XCTest
@testable import CloudKitSyncClient
@testable import ServerSyncClient
@testable import SSHCommandBuilder

final class CKRecordHostMappingForwardsTests: XCTestCase {
	private let zoneID = CKRecordZone.ID(zoneName: "Caterm")

	// MARK: - makeRecord (create path)

	func test_makeRecord_writesForwardsJsonAndMetadataUpdatedAt() throws {
		let input = RemoteHostCreateInput(
			name: "h", hostname: "h.example", port: 22, username: "u",
			forwards: [PortForward(kind: .local, bindPort: 5432,
			                       remoteHost: "db", remotePort: 5432)]
		)
		let rec = CKRecordHostMapping.makeRecord(
			recordName: "rec",
			zoneID: zoneID,
			input: input
		)
		let json = rec["forwards"] as? String ?? ""
		XCTAssertTrue(json.contains("\"bindPort\":5432"))
		XCTAssertNotNil(rec["metadataUpdatedAt"] as? Date)
	}

	func test_makeRecord_writesEmptyArrayWhenNoForwards() throws {
		let input = RemoteHostCreateInput(
			name: "h", hostname: "h.example", port: 22, username: "u"
		)
		let rec = CKRecordHostMapping.makeRecord(
			recordName: "rec-empty",
			zoneID: zoneID,
			input: input
		)
		XCTAssertEqual(rec["forwards"] as? String, "[]")
	}

	// MARK: - applyMetadata (update path)

	func test_applyMetadata_writesForwardsAndAdvancesMetadataUpdatedAt() throws {
		let rec = CKRecord(recordType: "Host",
		                   recordID: .init(recordName: "rec",
		                                   zoneID: zoneID))
		let original = Date(timeIntervalSince1970: 1000)
		rec["metadataUpdatedAt"] = original as CKRecordValue
		let host = SSHHost(
			id: UUID(), serverId: "rec",
			name: "h", hostname: "h.example", port: 22,
			username: "u", credential: .password,
			updatedAt: Date(timeIntervalSince1970: 2000),
			forwards: [
				PortForward(kind: .dynamic, bindPort: 1080),
			]
		)
		CKRecordHostMapping.applyMetadata(into: rec, from: host)
		let json = rec["forwards"] as? String ?? ""
		XCTAssertTrue(json.contains("\"kind\":\"dynamic\""))
		XCTAssertEqual((rec["metadataUpdatedAt"] as? Date)?.timeIntervalSince1970, 2000)
	}

	// MARK: - decode (pull path)

	func test_pull_absentForwards_decodesEmpty() throws {
		let rec = CKRecord(recordType: "Host",
		                   recordID: .init(recordName: "rec",
		                                   zoneID: zoneID))
		rec["name"] = "h" as CKRecordValue
		rec["hostname"] = "h.example" as CKRecordValue
		rec["port"] = 22 as CKRecordValue
		rec["username"] = "u" as CKRecordValue
		rec["authType"] = "key" as CKRecordValue
		rec["metadataUpdatedAt"] = Date() as CKRecordValue
		let result = try CKRecordHostMapping.decode(rec)
		XCTAssertEqual(result.host.forwards, [])
	}

	func test_pull_corruptForwardsJson_degradesToEmpty() throws {
		let rec = CKRecord(recordType: "Host",
		                   recordID: .init(recordName: "rec",
		                                   zoneID: zoneID))
		rec["name"] = "h" as CKRecordValue
		rec["hostname"] = "h.example" as CKRecordValue
		rec["port"] = 22 as CKRecordValue
		rec["username"] = "u" as CKRecordValue
		rec["authType"] = "key" as CKRecordValue
		rec["metadataUpdatedAt"] = Date() as CKRecordValue
		rec["forwards"] = "{not valid json}" as CKRecordValue
		let result = try CKRecordHostMapping.decode(rec)
		XCTAssertEqual(result.host.forwards, [])
	}

	func test_pull_validForwardsJson_decodesEntries() throws {
		let rec = CKRecord(recordType: "Host",
		                   recordID: .init(recordName: "rec",
		                                   zoneID: zoneID))
		rec["name"] = "h" as CKRecordValue
		rec["hostname"] = "h.example" as CKRecordValue
		rec["port"] = 22 as CKRecordValue
		rec["username"] = "u" as CKRecordValue
		rec["authType"] = "key" as CKRecordValue
		rec["metadataUpdatedAt"] = Date() as CKRecordValue
		let forwards = [
			PortForward(kind: .local, bindPort: 5432,
			            remoteHost: "db", remotePort: 5432),
			PortForward(kind: .dynamic, bindPort: 1080),
		]
		let data = try JSONEncoder().encode(forwards)
		let json = String(data: data, encoding: .utf8)!
		rec["forwards"] = json as CKRecordValue
		let result = try CKRecordHostMapping.decode(rec)
		XCTAssertEqual(result.host.forwards, forwards)
	}
}
