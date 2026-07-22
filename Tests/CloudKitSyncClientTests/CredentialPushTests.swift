import CloudKit
import CredentialSyncTypes
import ServerSyncClient
import XCTest
@testable import CloudKitSyncClient

final class CredentialPushTests: XCTestCase {
	var fakeDb: FakeCloudDatabase!
	var sut: CloudKitSyncClient!
	let zoneID = CKRecordZone.ID(zoneName: "Caterm")

	override func setUp() {
		fakeDb = FakeCloudDatabase()
		sut = CloudKitSyncClient(database: fakeDb, zoneID: zoneID)
	}

	private func makeBaseRecord(recordName: String) -> CKRecord {
		let recID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
		let rec = CKRecord(recordType: "Host", recordID: recID)
		rec[CKRecordHostMapping.Field.name] = "n" as CKRecordValue
		rec[CKRecordHostMapping.Field.hostname] = "h" as CKRecordValue
		rec[CKRecordHostMapping.Field.port] = 22 as CKRecordValue
		rec[CKRecordHostMapping.Field.username] = "u" as CKRecordValue
		return rec
	}

	func test_push_seedsMetadataUpdatedAt_whenAbsent() async throws {
		let existing = makeBaseRecord(recordName: "rec-1")
		// No metadataUpdatedAt set — push should seed it before applying blob.
		fakeDb.records[existing.recordID] = existing

		let blob = CredentialBlob(
			state: .payload,
			revision: 1,
			keyID: "K",
			passwordCiphertext: Data("ct".utf8)
		)

		let returned = try await sut.pushHostCredentialBlob(
			serverId: "rec-1", blob: blob
		)

		XCTAssertEqual(returned, 1)
		XCTAssertEqual(fakeDb.saveCallCount, 1)

		let saved = fakeDb.records[existing.recordID]
		XCTAssertNotNil(saved)
		// Test-constructed CKRecord has no modificationDate/creationDate, so
		// the seed falls back to Date.distantPast.
		let seeded = saved?[CKRecordHostMapping.Field.metadataUpdatedAt] as? Date
		XCTAssertEqual(seeded, .distantPast)
		XCTAssertEqual(
			saved?[CKRecordHostMapping.Field.credentialBlobState] as? String,
			"payload"
		)
		XCTAssertEqual(
			saved?[CKRecordHostMapping.Field.credentialBlobRevision] as? Int64,
			1
		)
		XCTAssertEqual(
			saved?[CKRecordHostMapping.Field.credentialKeyID] as? String,
			"K"
		)
		XCTAssertEqual(
			saved?[CKRecordHostMapping.Field.passwordCiphertext] as? Data,
			Data("ct".utf8)
		)
	}

	func test_push_doesNotOverwriteExistingMetadataUpdatedAt() async throws {
		let existing = makeBaseRecord(recordName: "rec-2")
		let preset = Date(timeIntervalSince1970: 5000)
		existing[CKRecordHostMapping.Field.metadataUpdatedAt] = preset as CKRecordValue
		fakeDb.records[existing.recordID] = existing

		let blob = CredentialBlob(
			state: .payload,
			revision: 7,
			keyID: "K2",
			passwordCiphertext: Data("ct2".utf8)
		)

		let returned = try await sut.pushHostCredentialBlob(
			serverId: "rec-2", blob: blob
		)

		XCTAssertEqual(returned, 7)
		XCTAssertEqual(fakeDb.saveCallCount, 1)

		let saved = fakeDb.records[existing.recordID]
		let unchanged = saved?[CKRecordHostMapping.Field.metadataUpdatedAt] as? Date
		XCTAssertEqual(unchanged, preset)
		XCTAssertEqual(
			saved?[CKRecordHostMapping.Field.credentialBlobState] as? String,
			"payload"
		)
		XCTAssertEqual(
			saved?[CKRecordHostMapping.Field.credentialBlobRevision] as? Int64,
			7
		)
	}

	func test_pushMissingHostRequestsFullReconciliation() async throws {
		let blob = CredentialBlob(
			state: .payload,
			revision: 1,
			keyID: "K"
		)

		do {
			_ = try await sut.pushHostCredentialBlob(
				serverId: "missing",
				blob: blob
			)
			XCTFail("Expected missing Host error")
		} catch let error as ServerSyncError {
			XCTAssertEqual(
				error,
				.remoteHostNotFound(serverID: "missing")
			)
		}
	}
}
