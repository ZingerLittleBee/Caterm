import CloudKit
import XCTest
@testable import CloudKitSyncClient
@testable import ServerSyncClient
@testable import SSHCommandBuilder

final class CKRecordHostMappingOrganizationTests: XCTestCase {
	private let zoneID = CKRecordZone.ID(zoneName: "Caterm")

	func testCreateAndDecodeRoundTripOrganization() throws {
		let organization = HostOrganization(
			groupPath: ["Production", "API"], tags: ["Linux", "Critical"]
		)
		let record = CKRecordHostMapping.makeRecord(
			recordName: "host-1",
			zoneID: zoneID,
			input: RemoteHostCreateInput(
				name: "API", hostname: "api.example", port: 22,
				username: "deploy", organization: organization
			)
		)

		XCTAssertNotNil(record["organization"] as? String)
		XCTAssertEqual(try CKRecordHostMapping.decode(record).host.organization, organization)
	}

	func testDecodeMissingOrganizationUsesEmptyValue() throws {
		let record = CKRecord(
			recordType: "Host",
			recordID: .init(recordName: "legacy", zoneID: zoneID)
		)
		record["name"] = "Legacy" as CKRecordValue
		record["hostname"] = "legacy.example" as CKRecordValue
		record["port"] = 22 as CKRecordValue
		record["username"] = "root" as CKRecordValue

		XCTAssertEqual(try CKRecordHostMapping.decode(record).host.organization, .empty)
	}

	func testUpdateHostPersistsCompleteMetadataSnapshot() async throws {
		let database = FakeCloudDatabase()
		let client = CloudKitSyncClient(
			database: database,
			zoneID: zoneID,
			tokenStore: InMemoryServerChangeTokenStore()
		)
		let recordID = CKRecord.ID(recordName: "host-1", zoneID: zoneID)
		let record = CKRecord(recordType: "Host", recordID: recordID)
		record["credentialBlobState"] = "payload" as CKRecordValue
		record["credentialBlobRevision"] = Int64(3) as CKRecordValue
		record["icon"] = "old.icon" as CKRecordValue
		database.records[recordID] = record
		let organization = HostOrganization(
			groupPath: ["Staging"], tags: ["Linux"]
		)
		let timestamp = Date(timeIntervalSince1970: 2_000)

		try await client.updateHost(RemoteHostUpdateInput(
			id: "host-1", name: "Web", hostname: "web.example", port: 2202,
			username: "deploy", jumpHostServerId: nil, forwards: [], icon: nil,
			organization: organization, metadataUpdatedAt: timestamp
		))

		let saved = try XCTUnwrap(database.savedRecords.last)
		XCTAssertEqual(saved["name"] as? String, "Web")
		XCTAssertEqual(saved["metadataUpdatedAt"] as? Date, timestamp)
		XCTAssertNil(saved["icon"])
		XCTAssertEqual(saved["credentialBlobState"] as? String, "payload")
		XCTAssertEqual(saved["credentialBlobRevision"] as? Int64, 3)
		XCTAssertEqual(try CKRecordHostMapping.decode(saved).host.organization, organization)
	}
}
