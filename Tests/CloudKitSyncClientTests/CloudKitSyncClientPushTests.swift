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

    func testCommitHostCheckpointPersistsBothDbAndZoneTokens() async throws {
        let token: CKServerChangeToken
        do {
            token = try FakeCloudDatabase.makeRealishToken()
        } catch {
            throw XCTSkip("FakeCloudDatabase.makeRealishToken byte fixture rejected by current toolchain")
        }
        fakeDB.enqueueDatabaseChanges(.init(changedZoneIDs: [zoneID],
                                            newToken: token, moreComing: false))
        fakeDB.enqueueZoneChanges(zoneID, .init(newToken: token, moreComing: false))

        let batch = try await client.fetchHostChanges()
        let checkpoint = try XCTUnwrap(batch.checkpoint)
        try await client.commitHostCheckpoint(checkpoint)

        let stored = await tokenStore.loadDatabaseToken()
        XCTAssertNotNil(stored)
    }

    func testForceFullWithExistingTokensCommitsFreshCheckpoint() async throws {
        let pre: CKServerChangeToken
        let post: CKServerChangeToken
        do {
            pre = try FakeCloudDatabase.makeRealishToken()
            post = try FakeCloudDatabase.makeRealishToken()
        } catch {
            throw XCTSkip("FakeCloudDatabase.makeRealishToken byte fixture rejected by current toolchain")
        }
        let preArchived = try StoredServerChangeToken.archive(pre)
        let epoch = await tokenStore.currentEpoch()
        _ = await tokenStore.commitTokens(
            expectedEpoch: epoch,
            db: TokenCAS(prev: nil, new: preArchived.archivedData),
            zones: [:]
        )

        fakeDB.enqueueDatabaseChanges(.init(newToken: post, moreComing: false))

        let batch = try await client.fetchHostSnapshotAndCheckpoint()
        let cp = try XCTUnwrap(batch.checkpoint)
        try await client.commitHostCheckpoint(cp)

        let stored = await tokenStore.loadDatabaseToken()
        XCTAssertNotNil(stored)
        XCTAssertNotEqual(stored?.archivedData, preArchived.archivedData,
                          "commit must replace the prior archive with the fresh server token")
    }

    func testCommitHostCheckpointRejectsForeignCheckpointType() async throws {
        struct ForeignCheckpoint: HostSyncCheckpoint { let id = UUID() }
        try await client.commitHostCheckpoint(ForeignCheckpoint())
        let stored = await tokenStore.loadDatabaseToken()
        XCTAssertNil(stored, "foreign checkpoint must be silently rejected")
    }

    func testResetDuringApplyPreventsStaleCheckpointCommit() async throws {
        fakeDB.enqueueDatabaseChanges(.init(newToken: nil, moreComing: false))
        let batch = try await client.fetchHostChanges()
        let cp = try XCTUnwrap(batch.checkpoint)
        await client.resetHostSyncState()  // bumps epoch
        try await client.commitHostCheckpoint(cp)

        let stored = await tokenStore.loadDatabaseToken()
        XCTAssertNil(stored, "reset bumped epoch ⇒ commit must be staleEpoch")
    }

    // MARK: - Subscription management

    func testEnsureHostSubscriptionCreatesNewWhenMissing() async throws {
        try await client.ensureHostSubscription()
        XCTAssertEqual(fakeDB.savedSubscriptions.count, 1)
        let sub = try XCTUnwrap(fakeDB.savedSubscriptions.first as? CKDatabaseSubscription)
        XCTAssertEqual(sub.subscriptionID, CloudKitPushNames.hostSubscriptionID)
        XCTAssertEqual(sub.recordType, "Host")
        XCTAssertTrue(sub.notificationInfo?.shouldSendContentAvailable ?? false)
    }

    func testEnsureHostSubscriptionTreatsAlreadyExistsAsSuccess() async throws {
        fakeDB.saveSubscriptionError = CKError(.serverRejectedRequest)
        try await client.ensureHostSubscription()  // must not throw
    }

    func testEnsureHostSubscriptionPropagatesNonExistsError() async throws {
        fakeDB.saveSubscriptionError = CKError(.networkFailure)
        do {
            try await client.ensureHostSubscription()
            XCTFail("expected throw")
        } catch let e as CKError {
            XCTAssertEqual(e.code, .networkFailure)
        }
    }

    func testDeleteHostSubscriptionTreatsUnknownItemAsSuccess() async throws {
        fakeDB.deleteSubscriptionError = CKError(.unknownItem)
        try await client.deleteHostSubscription()  // must not throw
    }

    func testDeleteHostSubscriptionRemovesExistingSubscription() async throws {
        try await client.deleteHostSubscription()
        XCTAssertEqual(fakeDB.deletedSubscriptionIDs.count, 1)
        XCTAssertEqual(fakeDB.deletedSubscriptionIDs.first, CloudKitPushNames.hostSubscriptionID)
    }
}
