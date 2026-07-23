import CloudKit
import XCTest
@testable import CloudKitSyncClient
@testable import ServerSyncClient
@testable import SSHCommandBuilder

final class CKRecordHostMappingAutomationTests: XCTestCase {
	private let zoneID = CKRecordZone.ID(zoneName: "Caterm")

	func testCreateDecodeAndMetadataUpdatePreserveAutomation() throws {
		let first = HostAutomation(
			isEnabled: true,
			startupSnippetID: UUID(),
			environment: [
				HostEnvironmentVariable(name: "REGION", value: "west")
			],
			reviewPolicy: .always,
			reconnectPolicy: .oncePerSession
		)
		let record = CKRecordHostMapping.makeRecord(
			recordName: "host-automation",
			zoneID: zoneID,
			input: RemoteHostCreateInput(
				name: "Automated",
				hostname: "automation.example",
				port: 22,
				username: "deploy",
				automation: first
			)
		)

		XCTAssertEqual(try CKRecordHostMapping.decode(record).host.automation, first)

		let second = HostAutomation(
			isEnabled: false,
			startupSnippetID: first.startupSnippetID,
			environment: first.environment,
			reviewPolicy: .never,
			reconnectPolicy: .everyConnection
		)
		CKRecordHostMapping.applyMetadata(
			into: record,
			from: RemoteHostUpdateInput(
				id: "host-automation",
				automation: second
			)
		)

		XCTAssertEqual(try CKRecordHostMapping.decode(record).host.automation, second)
	}

	func testLegacyRecordDecodesWithDisabledAutomation() throws {
		let record = CKRecord(
			recordType: "Host",
			recordID: .init(recordName: "legacy", zoneID: zoneID)
		)
		record["name"] = "Legacy" as CKRecordValue
		record["hostname"] = "legacy.example" as CKRecordValue
		record["port"] = 22 as CKRecordValue
		record["username"] = "deploy" as CKRecordValue

		XCTAssertEqual(
			try CKRecordHostMapping.decode(record).host.automation,
			.disabled
		)
	}
}
