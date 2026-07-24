import CloudKit
@testable import CloudKitSyncClient
import Foundation
import ServerSyncClient
import SSHCommandBuilder
import Testing

struct CKRecordHostMappingCredentialIdentityTests {
	@Test
	func assignmentRoundTripsAsHostMetadata() throws {
		let zoneID = CKRecordZone.ID(
			zoneName: "test",
			ownerName: CKCurrentUserDefaultName
		)
		let reference = HostCredentialIdentityReference(
			identityID: UUID(),
			migrationState: .reversible
		)
		let record = CKRecordHostMapping.makeRecord(
			recordName: "host-1",
			zoneID: zoneID,
			input: RemoteHostCreateInput(
				name: "Host",
				hostname: "host.example",
				port: 22,
				username: "legacy",
				credentialIdentity: reference
			)
		)

		let decoded = try CKRecordHostMapping.decode(record).host

		#expect(decoded.credentialIdentity == reference)
		#expect(decoded.username == "legacy")
	}

	@Test
	func metadataUpdateCanClearAssignment() throws {
		let zoneID = CKRecordZone.ID(
			zoneName: "test",
			ownerName: CKCurrentUserDefaultName
		)
		let record = CKRecordHostMapping.makeRecord(
			recordName: "host-1",
			zoneID: zoneID,
			input: RemoteHostCreateInput(
				name: "Host",
				hostname: "host.example",
				port: 22,
				username: "legacy",
				credentialIdentity: HostCredentialIdentityReference(
					identityID: UUID()
				)
			)
		)

		CKRecordHostMapping.applyMetadata(
			into: record,
			from: RemoteHostUpdateInput(
				id: "host-1",
				credentialIdentity: nil
			)
		)

		#expect(try CKRecordHostMapping.decode(record).host
			.credentialIdentity == nil)
	}

	@Test
	func legacyRecordDecodesWithoutAssignment() throws {
		let zoneID = CKRecordZone.ID(
			zoneName: "test",
			ownerName: CKCurrentUserDefaultName
		)
		let record = CKRecordHostMapping.makeRecord(
			recordName: "host-1",
			zoneID: zoneID,
			input: RemoteHostCreateInput(
				name: "Host",
				hostname: "host.example",
				port: 22,
				username: "legacy"
			)
		)
		record["credentialIdentity"] = nil

		#expect(try CKRecordHostMapping.decode(record).host
			.credentialIdentity == nil)
	}
}
