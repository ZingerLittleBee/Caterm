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
		let record = makeLegacyRecord(recordName: "legacy")

		XCTAssertEqual(
			try CKRecordHostMapping.decode(record).host.automation,
			.disabled
		)
	}

	func testMalformedAutomationDoesNotDecodeAsDisabled() {
		let record = makeLegacyRecord(recordName: "malformed")
		record["automation"] = "{not-json" as CKRecordValue

		XCTAssertThrowsError(try CKRecordHostMapping.decode(record)) { error in
			guard case CKRecordHostMapping.DecodeError.invalidAutomation =
				error else {
				return XCTFail("Expected invalidAutomation, got \(error)")
			}
		}
	}

	func testInvalidAutomationDoesNotDecodeAsDisabled() throws {
		let record = makeLegacyRecord(recordName: "invalid")
		let invalid = HostAutomation(
			isEnabled: true,
			environment: [
				HostEnvironmentVariable(name: "INVALID-NAME", value: "value")
			]
		)
		record["automation"] = try XCTUnwrap(
			String(data: JSONEncoder().encode(invalid), encoding: .utf8)
		) as CKRecordValue

		XCTAssertThrowsError(try CKRecordHostMapping.decode(record)) { error in
			XCTAssertEqual(
				error as? CKRecordHostMapping.DecodeError,
				.invalidAutomation(
					"INVALID-NAME is not a valid environment variable name."
				)
			)
		}
	}

	private func makeLegacyRecord(recordName: String) -> CKRecord {
		let record = CKRecord(
			recordType: "Host",
			recordID: .init(recordName: recordName, zoneID: zoneID)
		)
		record["name"] = "Legacy" as CKRecordValue
		record["hostname"] = "legacy.example" as CKRecordValue
		record["port"] = 22 as CKRecordValue
		record["username"] = "deploy" as CKRecordValue

		return record
	}
}
