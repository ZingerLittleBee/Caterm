import CloudKit
import CredentialIdentityStore
import XCTest
@testable import CloudKitSyncClient

final class CKRecordCredentialIdentityMappingTests: XCTestCase {
	func test_makeRecord_roundTripsMetadataAndEncryptedMaterial() throws {
		let identity = makeIdentity()
		let syncRecord = CredentialIdentitySyncRecord(
			identity: identity,
			keyID: "key-v1",
			cryptoVersion: 1,
			passwordCiphertext: Data([1, 2]),
			passphraseCiphertext: Data([3, 4]),
			privateKeyCiphertext: Data([5, 6])
		)
		let zoneID = CKRecordZone.ID(zoneName: "Caterm")

		let cloudRecord = try CKRecordCredentialIdentityMapping.makeRecord(
			record: syncRecord,
			zoneID: zoneID
		)
		let decoded = try CKRecordCredentialIdentityMapping.decode(cloudRecord)

		XCTAssertEqual(cloudRecord.recordID.recordName, identity.id.uuidString)
		XCTAssertEqual(cloudRecord.recordID.zoneID, zoneID)
		XCTAssertEqual(decoded.identity.id, identity.id)
		XCTAssertEqual(decoded.identity.serverID, identity.id.uuidString)
		XCTAssertEqual(decoded.identity.name, identity.name)
		XCTAssertEqual(decoded.identity.username, identity.username)
		XCTAssertEqual(decoded.identity.source, identity.source)
		XCTAssertEqual(decoded.keyID, "key-v1")
		XCTAssertEqual(decoded.passwordCiphertext, Data([1, 2]))
		XCTAssertEqual(decoded.passphraseCiphertext, Data([3, 4]))
		XCTAssertEqual(decoded.privateKeyCiphertext, Data([5, 6]))
	}

	func test_decode_rejectsMetadataWhoseIdentityDoesNotMatchRecordName()
		throws {
		let identity = makeIdentity()
		let zoneID = CKRecordZone.ID(zoneName: "Caterm")
		let cloudRecord = try CKRecordCredentialIdentityMapping.makeRecord(
			record: CredentialIdentitySyncRecord(identity: identity),
			zoneID: zoneID
		)
		let mismatchedID = CKRecord.ID(
			recordName: UUID().uuidString,
			zoneID: zoneID
		)
		let mismatched = CKRecord(
			recordType: cloudRecord.recordType,
			recordID: mismatchedID
		)
		mismatched["metadata"] = cloudRecord["metadata"]

		XCTAssertThrowsError(
			try CKRecordCredentialIdentityMapping.decode(mismatched)
		) { error in
			XCTAssertEqual(
				error as? CKRecordCredentialIdentityMapping.MappingError,
				.invalidMetadata
			)
		}
	}
}

final class CloudKitCredentialIdentitySyncTests: XCTestCase {
	func test_queryPaginationCollectsEveryPage() async throws {
		let pages: [Int: ([String], Int?)] = [
			0: (["first"], 1),
			1: (["second"], 2),
			2: (["third"], nil),
		]

		let values = try await collectAllQueryPages(
			first: { try XCTUnwrap(pages[0]) },
			next: { cursor in try XCTUnwrap(pages[cursor]) }
		)

		XCTAssertEqual(values, ["first", "second", "third"])
	}

	func test_upsertListAndDelete_useStableIdentityRecordID() async throws {
		let database = FakeCloudDatabase()
		let zoneID = CKRecordZone.ID(zoneName: "Caterm")
		let client = CloudKitSyncClient(
			database: database,
			zoneID: zoneID
		)
		let identity = makeIdentity()

		let serverID = try await client.upsertCredentialIdentity(
			CredentialIdentitySyncRecord(
				identity: identity,
				keyID: "key-v1",
				passwordCiphertext: Data([9, 8, 7])
			)
		)

		XCTAssertEqual(serverID, identity.id.uuidString)
		XCTAssertEqual(database.saveZoneCallCount, 1)
		XCTAssertEqual(database.savedRecords.last?.recordID.zoneID, zoneID)
		let listed = try await client.listCredentialIdentities()
		XCTAssertEqual(listed.count, 1)
		XCTAssertEqual(listed.first?.identity.id, identity.id)
		XCTAssertEqual(listed.first?.passwordCiphertext, Data([9, 8, 7]))

		try await client.deleteCredentialIdentity(id: serverID)
		XCTAssertEqual(
			database.deletedRecordIDs.last?.recordName,
			identity.id.uuidString
		)
		let remaining = try await client.listCredentialIdentities()
		XCTAssertTrue(remaining.isEmpty)
	}

	func test_list_failsWhenAnyIdentityRecordIsCorrupt()
		async throws {
		let database = FakeCloudDatabase()
		let zoneID = CKRecordZone.ID(zoneName: "Caterm")
		let client = CloudKitSyncClient(
			database: database,
			zoneID: zoneID
		)
		let identity = makeIdentity()
		let valid = try CKRecordCredentialIdentityMapping.makeRecord(
			record: CredentialIdentitySyncRecord(identity: identity),
			zoneID: zoneID
		)
		let corrupt = CKRecord(
			recordType: CKRecordCredentialIdentityMapping.recordType,
			recordID: CKRecord.ID(
				recordName: UUID().uuidString,
				zoneID: zoneID
			)
		)
		database.records[valid.recordID] = valid
		database.records[corrupt.recordID] = corrupt

		do {
			_ = try await client.listCredentialIdentities()
			XCTFail("Expected corrupt record to fail the complete snapshot")
		} catch {}
	}

	func test_list_failsWhenAnyCloudKitMatchFails() async throws {
		let database = FakeCloudDatabase()
		let zoneID = CKRecordZone.ID(zoneName: "Caterm")
		let client = CloudKitSyncClient(
			database: database,
			zoneID: zoneID
		)
		let recordID = CKRecord.ID(
			recordName: UUID().uuidString,
			zoneID: zoneID
		)
		database.recordMatchResults = [
			(
				recordID,
				.failure(CKError(.partialFailure))
			),
		]

		await XCTAssertThrowsErrorAsync {
			_ = try await client.listCredentialIdentities()
		}
	}
}

private func XCTAssertThrowsErrorAsync(
	_ expression: () async throws -> Void
) async {
	do {
		try await expression()
		XCTFail("Expected expression to throw")
	} catch {}
}

private func makeIdentity() -> CredentialIdentity {
	CredentialIdentity(
		id: UUID(),
		name: "Production",
		username: "deploy",
		source: .managedKey(
			materialID: CredentialMaterialID(),
			hasPassphrase: true
		),
		createdAt: Date(timeIntervalSince1970: 1),
		updatedAt: Date(timeIntervalSince1970: 2),
		revision: 3
	)
}
