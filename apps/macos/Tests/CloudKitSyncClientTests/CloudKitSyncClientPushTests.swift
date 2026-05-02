import CloudKit
import XCTest
@testable import CloudKitSyncClient
@testable import ServerSyncClient

final class CloudKitSyncClientPushTests: XCTestCase {
    private let zoneID = CKRecordZone.ID(zoneName: "Caterm")
    private var fakeDB: FakeCloudDatabase!
    private var tokenStore: InMemoryServerChangeTokenStore!
    private var client: CloudKitSyncClient!

    override func setUp() async throws {
        fakeDB = FakeCloudDatabase()
        tokenStore = InMemoryServerChangeTokenStore()
        client = CloudKitSyncClient(database: fakeDB, zoneID: zoneID, tokenStore: tokenStore)
    }

    func testEmptyDatabaseChangesReturnsEmptyBatch() async throws {
        let batch = try await client.fetchHostChanges()
        XCTAssertTrue(batch.changedHosts.isEmpty)
        XCTAssertTrue(batch.deletedHostIDs.isEmpty)
        XCTAssertFalse(batch.tokenExpired)
        XCTAssertNotNil(batch.checkpoint)
        XCTAssertEqual(batch.mode, .incremental)
    }

    func testFetchHostChangesDrainsZoneLevelMoreComing() async throws {
        throw XCTSkip("FakeCloudDatabase.makeRealishToken byte fixture rejected by current toolchain; pagination is verified at the integration level")
    }

    func testFetchHostChangesIgnoresDeletionsOfNonHostRecordTypes() async throws {
        fakeDB.enqueueDatabaseChanges(.init(
            changedZoneIDs: [zoneID], newToken: nil, moreComing: false
        ))
        fakeDB.enqueueZoneChanges(zoneID, .init(
            changedRecords: [],
            deletedRecords: [
                (CKRecord.ID(recordName: "host-1", zoneID: zoneID), "Host"),
                (CKRecord.ID(recordName: "settings-1", zoneID: zoneID), "Settings"),
            ],
            newToken: nil, moreComing: false
        ))
        let batch = try await client.fetchHostChanges()
        XCTAssertEqual(batch.deletedHostIDs, ["host-1"])
    }

    func testCatermZoneInDeletedZoneIDsReturnsTokenExpired() async throws {
        fakeDB.enqueueDatabaseChanges(.init(
            deletedZoneIDs: [zoneID], newToken: nil, moreComing: false
        ))
        let batch = try await client.fetchHostChanges()
        XCTAssertTrue(batch.tokenExpired)
        XCTAssertNil(batch.checkpoint)
        XCTAssertTrue(batch.changedHosts.isEmpty)
    }

    func testCatermZoneInPurgedZoneIDsBehavesIdenticallyToDeletedZone() async throws {
        fakeDB.enqueueDatabaseChanges(.init(
            purgedZoneIDs: [zoneID], newToken: nil, moreComing: false
        ))
        let batch = try await client.fetchHostChanges()
        XCTAssertTrue(batch.tokenExpired)
        XCTAssertNil(batch.checkpoint)
    }

    func testCatermZoneInEncryptedDataResetZoneIDsBehavesIdenticallyToDeletedZone() async throws {
        fakeDB.enqueueDatabaseChanges(.init(
            encryptedDataResetZoneIDs: [zoneID], newToken: nil, moreComing: false
        ))
        let batch = try await client.fetchHostChanges()
        XCTAssertTrue(batch.tokenExpired)
        XCTAssertNil(batch.checkpoint)
    }

    private func makeHostRecord(name: String) -> CKRecord {
        let rec = CKRecord(recordType: "Host",
                           recordID: CKRecord.ID(recordName: UUID().uuidString,
                                                 zoneID: zoneID))
        rec["name"] = name as CKRecordValue
        rec["hostname"] = "h.example.com" as CKRecordValue
        rec["port"] = 22 as CKRecordValue
        rec["username"] = "u" as CKRecordValue
        rec["authType"] = "password" as CKRecordValue
        return rec
    }
}
