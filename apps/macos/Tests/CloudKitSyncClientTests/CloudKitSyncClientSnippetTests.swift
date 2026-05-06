import CloudKit
import XCTest
import SnippetSyncClient
@testable import CloudKitSyncClient

// MARK: - CloudKitSyncClient snippet push/delete/subscription tests

final class CloudKitSyncClientSnippetTests: XCTestCase {
	func test_pushSnippet_savesToSnippetsZone() async throws {
		let fakeDB = FakeCloudDatabase()
		let client = CloudKitSyncClient(
			database: fakeDB,
			zoneID: CKRecordZone.ID(zoneName: "Caterm", ownerName: CKCurrentUserDefaultName)
		)
		let s = Snippet(id: UUID(), name: "n", content: "c",
		                createdAt: .now, updatedAt: .now)
		_ = try await client.pushSnippet(s)
		let saved = try XCTUnwrap(fakeDB.savedRecords.last)
		XCTAssertEqual(saved.recordID.zoneID.zoneName,
		               CloudKitPushNames.snippetZoneName,
		               "Snippets must land in the Snippets zone, not the Caterm host zone")
	}

	func test_deleteSnippet_callsDeleteWithSnippetZoneID() async throws {
		let fakeDB = FakeCloudDatabase()
		let client = CloudKitSyncClient(
			database: fakeDB,
			zoneID: CKRecordZone.ID(zoneName: "Caterm", ownerName: CKCurrentUserDefaultName)
		)
		let id = UUID()
		try await client.deleteSnippet(id: id)
		let deleted = try XCTUnwrap(fakeDB.deletedRecordIDs.last)
		XCTAssertEqual(deleted.recordName, id.uuidString)
		XCTAssertEqual(deleted.zoneID.zoneName, CloudKitPushNames.snippetZoneName)
	}

	func test_ensureSnippetSubscription_isIdempotent() async throws {
		let fakeDB = FakeCloudDatabase()
		let client = CloudKitSyncClient(
			database: fakeDB,
			zoneID: CKRecordZone.ID(zoneName: "Caterm", ownerName: CKCurrentUserDefaultName)
		)
		try await client.ensureSnippetSubscription()
		try await client.ensureSnippetSubscription()
		// Both calls must succeed and each must have saved a subscription.
		XCTAssertEqual(fakeDB.savedSubscriptionIDs.filter {
			$0 == CloudKitPushNames.snippetSubscriptionID
		}.count, 2)
	}
}

// MARK: - CloudKitSyncClient snippet fetch + checkpoint tests

final class CloudKitSyncClientSnippetFetchTests: XCTestCase {
	private var fakeDB: FakeCloudDatabase!
	private var snippetTokenStore: InMemoryServerChangeTokenStore!
	private var client: CloudKitSyncClient!
	private let snippetZoneID = CKRecordZone.ID(
		zoneName: CloudKitPushNames.snippetZoneName,
		ownerName: CKCurrentUserDefaultName
	)

	override func setUp() async throws {
		fakeDB = FakeCloudDatabase()
		snippetTokenStore = InMemoryServerChangeTokenStore()
		client = CloudKitSyncClient(
			database: fakeDB,
			zoneID: CKRecordZone.ID(zoneName: "Caterm"),
			tokenStore: InMemoryServerChangeTokenStore(),
			snippetTokenStore: snippetTokenStore
		)
	}

	func test_fetchSnippetChanges_decodesChangedRecords() async throws {
		let id = UUID()
		fakeDB.enqueueZoneChanges(snippetZoneID, ZoneChangesScript(
			changedRecords: [makeFakeSnippetRecord(id: id, name: "n")],
			moreComing: false
		))
		let batch = try await client.fetchSnippetChanges()
		XCTAssertEqual(batch.changedSnippets.count, 1)
		XCTAssertEqual(batch.changedSnippets.first?.id, id)
		XCTAssertEqual(batch.mode, .incremental)
	}

	func test_fetchSnippetChanges_decodesTombstones() async throws {
		let id = UUID()
		let deletedID = CKRecord.ID(recordName: id.uuidString, zoneID: snippetZoneID)
		fakeDB.enqueueZoneChanges(snippetZoneID, ZoneChangesScript(
			deletedRecords: [(deletedID, CKRecordSnippetMapping.recordType)],
			moreComing: false
		))
		let batch = try await client.fetchSnippetChanges()
		XCTAssertEqual(batch.deletedSnippetIDs, [id])
	}

	func test_fetchSnippetChanges_corruptRecordIsSkipped() async throws {
		let goodID = UUID()
		fakeDB.enqueueZoneChanges(snippetZoneID, ZoneChangesScript(
			changedRecords: [
				makeFakeSnippetRecord(id: goodID, name: "n"),
				makeBrokenSnippetRecord(),
			],
			moreComing: false
		))
		let batch = try await client.fetchSnippetChanges()
		XCTAssertEqual(batch.changedSnippets.map(\.id), [goodID])
	}

	func test_fetchSnippetChanges_emptyZoneReturnsEmptyBatch() async throws {
		// No enqueue → FakeCloudDatabase returns ([], [], nil, false)
		let batch = try await client.fetchSnippetChanges()
		XCTAssertTrue(batch.changedSnippets.isEmpty)
		XCTAssertTrue(batch.deletedSnippetIDs.isEmpty)
		XCTAssertFalse(batch.tokenExpired)
		XCTAssertNotNil(batch.checkpoint)
		XCTAssertEqual(batch.mode, .incremental)
	}

	func test_commitSnippetCheckpoint_persistsZoneToken() async throws {
		let token: CKServerChangeToken
		do {
			token = try FakeCloudDatabase.makeRealishToken()
		} catch {
			throw XCTSkip("makeRealishToken byte fixture rejected by current toolchain")
		}
		fakeDB.enqueueZoneChanges(snippetZoneID, ZoneChangesScript(
			newToken: token, moreComing: false
		))
		let batch = try await client.fetchSnippetChanges()
		let checkpoint = try XCTUnwrap(batch.checkpoint)
		try await client.commitSnippetCheckpoint(checkpoint)
		let stored = await snippetTokenStore.loadZoneToken(snippetZoneID)
		XCTAssertNotNil(stored)
	}

	func test_commitSnippetCheckpoint_rejectsForeignType() async throws {
		struct ForeignCheckpoint: SnippetSyncCheckpoint { let id = UUID() }
		try await client.commitSnippetCheckpoint(ForeignCheckpoint())
		let stored = await snippetTokenStore.loadZoneToken(snippetZoneID)
		XCTAssertNil(stored, "foreign checkpoint must be silently rejected")
	}

	func test_resetDuringApply_preventsStaleCheckpointCommit() async throws {
		fakeDB.enqueueZoneChanges(snippetZoneID, ZoneChangesScript(moreComing: false))
		let batch = try await client.fetchSnippetChanges()
		let cp = try XCTUnwrap(batch.checkpoint)
		await client.resetSnippetSyncState()  // bumps epoch
		try await client.commitSnippetCheckpoint(cp)
		let stored = await snippetTokenStore.loadZoneToken(snippetZoneID)
		XCTAssertNil(stored, "reset bumped epoch ⇒ staleEpoch must prevent commit")
	}

	// MARK: - Helpers

	private func makeFakeSnippetRecord(id: UUID, name: String) -> CKRecord {
		let recID = CKRecord.ID(recordName: id.uuidString, zoneID: snippetZoneID)
		let rec = CKRecord(recordType: CKRecordSnippetMapping.recordType, recordID: recID)
		rec["name"] = name as CKRecordValue
		rec["content"] = "c" as CKRecordValue
		rec["createdAt"] = Date() as CKRecordValue
		rec["updatedAt"] = Date() as CKRecordValue
		rec["revision"] = Int64(1) as CKRecordValue
		rec["schemaVersion"] = Int64(1) as CKRecordValue
		return rec
	}

	private func makeBrokenSnippetRecord() -> CKRecord {
		let recID = CKRecord.ID(recordName: UUID().uuidString, zoneID: snippetZoneID)
		let rec = CKRecord(recordType: CKRecordSnippetMapping.recordType, recordID: recID)
		rec["name"] = "n" as CKRecordValue
		// "content" intentionally omitted — decode must fail gracefully
		return rec
	}
}

// MARK: - CKRecordSnippetMapping encode/decode tests

final class CKRecordSnippetMappingTests: XCTestCase {
	func test_encode_setsAllFields() {
		let id = UUID()
		let s = Snippet(
			id: id, name: "n", content: "c",
			placeholders: nil,
			createdAt: Date(timeIntervalSince1970: 1),
			updatedAt: Date(timeIntervalSince1970: 2),
			serverId: nil, revision: 7, metadataUpdatedAt: nil
		)
		let zoneID = CKRecordZone.ID(zoneName: "Snippets",
		                             ownerName: CKCurrentUserDefaultName)
		let rec = CKRecordSnippetMapping.encode(s, zoneID: zoneID)
		XCTAssertEqual(rec.recordID.recordName, id.uuidString)
		XCTAssertEqual(rec.recordID.zoneID, zoneID)
		XCTAssertEqual(rec["name"] as? String, "n")
		XCTAssertEqual(rec["content"] as? String, "c")
		XCTAssertEqual(rec["createdAt"] as? Date, Date(timeIntervalSince1970: 1))
		XCTAssertEqual(rec["updatedAt"] as? Date, Date(timeIntervalSince1970: 2))
		XCTAssertEqual(rec["revision"] as? Int64, 7)
		XCTAssertEqual(rec["schemaVersion"] as? Int64, 1)
		XCTAssertNil(rec["placeholders"])
	}

	func test_decode_roundTripsCoreFields() throws {
		let id = UUID()
		let zoneID = CKRecordZone.ID(zoneName: "Snippets",
		                             ownerName: CKCurrentUserDefaultName)
		let recID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
		let rec = CKRecord(recordType: "Snippet", recordID: recID)
		rec["name"] = "n" as CKRecordValue
		rec["content"] = "c" as CKRecordValue
		rec["createdAt"] = Date(timeIntervalSince1970: 1) as CKRecordValue
		rec["updatedAt"] = Date(timeIntervalSince1970: 2) as CKRecordValue
		rec["revision"] = Int64(7) as CKRecordValue
		rec["schemaVersion"] = Int64(1) as CKRecordValue

		let decoded = try CKRecordSnippetMapping.decode(rec)
		XCTAssertEqual(decoded.id, id)
		XCTAssertEqual(decoded.name, "n")
		XCTAssertEqual(decoded.content, "c")
		XCTAssertEqual(decoded.revision, 7)
		XCTAssertEqual(decoded.serverId, id.uuidString)
		XCTAssertNil(decoded.placeholders)
	}

	func test_decode_missingRequiredField_throws() {
		let zoneID = CKRecordZone.ID(zoneName: "Snippets",
		                             ownerName: CKCurrentUserDefaultName)
		let recID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
		let rec = CKRecord(recordType: "Snippet", recordID: recID)
		rec["name"] = "n" as CKRecordValue
		// content is missing
		XCTAssertThrowsError(try CKRecordSnippetMapping.decode(rec))
	}

	func test_placeholders_roundTripJSONEncoded() throws {
		let zoneID = CKRecordZone.ID(zoneName: "Snippets",
		                             ownerName: CKCurrentUserDefaultName)
		let s = Snippet(id: UUID(), name: "n", content: "c",
		                placeholders: ["path", "user"],
		                createdAt: .now, updatedAt: .now)
		let rec = CKRecordSnippetMapping.encode(s, zoneID: zoneID)
		let decoded = try CKRecordSnippetMapping.decode(rec)
		XCTAssertEqual(decoded.placeholders, ["path", "user"])
	}
}
