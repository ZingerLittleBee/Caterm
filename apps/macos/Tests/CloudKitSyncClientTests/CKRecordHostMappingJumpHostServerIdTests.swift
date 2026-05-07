import CloudKit
import XCTest
@testable import CloudKitSyncClient
@testable import ServerSyncClient
@testable import SSHCommandBuilder

final class CKRecordHostMappingJumpHostServerIdTests: XCTestCase {
	private let zoneID = CKRecordZone.ID(zoneName: "Caterm")

	// MARK: - makeRecord (create path via RemoteHostCreateInput)

	func testMakeRecordWritesJumpHostServerId() {
		let input = RemoteHostCreateInput(
			name: "n", hostname: "h", port: 22, username: "u",
			jumpHostServerId: "ck-bastion"
		)
		let rec = CKRecordHostMapping.makeRecord(
			recordName: "test-1", zoneID: zoneID, input: input
		)
		XCTAssertEqual(rec["jumpHostServerId"] as? String, "ck-bastion")
	}

	func testMakeRecordOmitsJumpHostServerIdWhenNil() {
		let input = RemoteHostCreateInput(
			name: "n", hostname: "h", port: 22, username: "u"
		)
		let rec = CKRecordHostMapping.makeRecord(
			recordName: "test-2", zoneID: zoneID, input: input
		)
		XCTAssertNil(rec["jumpHostServerId"])
	}

	// MARK: - applyMetadata (update path: SSHHost → CKRecord)

	func testApplyMetadataWritesJumpHostServerId() {
		let recID = CKRecord.ID(recordName: "apply-jump", zoneID: zoneID)
		let rec = CKRecord(recordType: "Host", recordID: recID)
		let host = SSHHost(
			id: UUID(), serverId: "apply-jump",
			name: "n", hostname: "h", port: 22,
			username: "u", credential: .password,
			jumpHostServerId: "ck-bastion"
		)
		CKRecordHostMapping.applyMetadata(into: rec, from: host)
		XCTAssertEqual(rec["jumpHostServerId"] as? String, "ck-bastion")
	}

	func testApplyMetadataOmitsJumpHostServerIdWhenNil() {
		let recID = CKRecord.ID(recordName: "apply-jump-nil", zoneID: zoneID)
		let rec = CKRecord(recordType: "Host", recordID: recID)
		// Pre-populate to verify it gets cleared when host has nil
		rec["jumpHostServerId"] = "old-value" as CKRecordValue
		let host = SSHHost(
			id: UUID(), serverId: "apply-jump-nil",
			name: "n", hostname: "h", port: 22,
			username: "u", credential: .password
		)
		CKRecordHostMapping.applyMetadata(into: rec, from: host)
		XCTAssertNil(rec["jumpHostServerId"])
	}

	// MARK: - decode (fetch path: CKRecord → RemoteHost)

	func testDecodeReadsJumpHostServerId() throws {
		let recID = CKRecord.ID(recordName: "decode-jump", zoneID: zoneID)
		let rec = CKRecord(recordType: "Host", recordID: recID)
		rec["name"] = "n" as CKRecordValue
		rec["hostname"] = "h" as CKRecordValue
		rec["port"] = 22 as CKRecordValue
		rec["username"] = "u" as CKRecordValue
		rec["authType"] = "password" as CKRecordValue
		rec["metadataUpdatedAt"] = Date() as CKRecordValue
		rec["jumpHostServerId"] = "ck-bastion" as CKRecordValue
		let result = try CKRecordHostMapping.decode(rec)
		XCTAssertEqual(result.host.jumpHostServerId, "ck-bastion")
	}

	func testDecodeReturnsNilJumpHostServerIdWhenAbsent() throws {
		// Simulates an old CKRecord written before this field was added.
		// Spec §4.10: "Missing key → unchanged (decode-old-records compat)."
		let recID = CKRecord.ID(recordName: "decode-jump-absent", zoneID: zoneID)
		let rec = CKRecord(recordType: "Host", recordID: recID)
		rec["name"] = "n" as CKRecordValue
		rec["hostname"] = "h" as CKRecordValue
		rec["port"] = 22 as CKRecordValue
		rec["username"] = "u" as CKRecordValue
		rec["authType"] = "password" as CKRecordValue
		rec["metadataUpdatedAt"] = Date() as CKRecordValue
		// Note: no jumpHostServerId key — simulates an old-record decode.
		let result = try CKRecordHostMapping.decode(rec)
		XCTAssertNil(result.host.jumpHostServerId)
	}
}
