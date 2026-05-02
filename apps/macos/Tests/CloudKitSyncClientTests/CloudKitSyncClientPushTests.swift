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
}
