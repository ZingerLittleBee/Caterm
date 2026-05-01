import CloudKit
import ServerSyncClient
import XCTest
@testable import CloudKitSyncClient

final class CloudKitSyncClientTests: XCTestCase {
    var fakeDb: FakeCloudDatabase!
    var sut: CloudKitSyncClient!
    let zoneID = CKRecordZone.ID(zoneName: "Caterm")

    override func setUp() {
        fakeDb = FakeCloudDatabase()
        sut = CloudKitSyncClient(database: fakeDb, zoneID: zoneID)
    }

    func testListHostsReturnsMappedRecords() async throws {
        let recID = CKRecord.ID(recordName: "h-1", zoneID: zoneID)
        let rec = CKRecord(recordType: "Host", recordID: recID)
        rec["name"] = "a" as CKRecordValue
        rec["hostname"] = "x" as CKRecordValue
        rec["port"] = 22 as CKRecordValue
        rec["username"] = "u" as CKRecordValue
        rec["authType"] = "key" as CKRecordValue
        fakeDb.records[recID] = rec

        let hosts = try await sut.listHosts()

        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].id, "h-1")
        XCTAssertEqual(hosts[0].name, "a")
        XCTAssertEqual(fakeDb.recordsCallCount, 1)
    }

    func testListHostsSkipsRecordsWithMissingFields() async throws {
        let goodID = CKRecord.ID(recordName: "good", zoneID: zoneID)
        let goodRec = CKRecord(recordType: "Host", recordID: goodID)
        goodRec["name"] = "a" as CKRecordValue
        goodRec["hostname"] = "x" as CKRecordValue
        goodRec["port"] = 22 as CKRecordValue
        goodRec["username"] = "u" as CKRecordValue
        fakeDb.records[goodID] = goodRec

        let badID = CKRecord.ID(recordName: "bad", zoneID: zoneID)
        let badRec = CKRecord(recordType: "Host", recordID: badID)
        badRec["name"] = "b" as CKRecordValue
        // missing hostname, port, username
        fakeDb.records[badID] = badRec

        let hosts = try await sut.listHosts()
        XCTAssertEqual(hosts.count, 1, "Malformed record must be skipped, not crash sync")
        XCTAssertEqual(hosts[0].id, "good")
    }

    func testCreateHostWritesRecordAndReturnsRecordName() async throws {
        let input = RemoteHostCreateInput(name: "alpha", hostname: "x",
                                          port: 22, username: "u")
        // The client allocates a fresh recordName per create. We cannot
        // assert the exact name (it's a UUID), but we can verify the saved
        // record matches and the returned id equals the allocated name.
        let out = try await sut.createHost(input)
        XCTAssertEqual(fakeDb.saveCallCount, 1)
        XCTAssertEqual(fakeDb.records.count, 1)
        let savedID = fakeDb.records.keys.first!
        XCTAssertEqual(savedID.recordName, out.id)
        XCTAssertEqual(fakeDb.records[savedID]?["name"] as? String, "alpha")
    }

    func testUpdateHostFetchesAndModifiesRecord() async throws {
        let recID = CKRecord.ID(recordName: "h-1", zoneID: zoneID)
        let existing = CKRecord(recordType: "Host", recordID: recID)
        existing["name"] = "old" as CKRecordValue
        existing["hostname"] = "old.example.com" as CKRecordValue
        existing["port"] = 22 as CKRecordValue
        existing["username"] = "old-u" as CKRecordValue
        existing["authType"] = "key" as CKRecordValue
        fakeDb.records[recID] = existing

        let input = RemoteHostUpdateInput(id: "h-1", name: "new",
                                          hostname: "new.example.com",
                                          port: 2222, username: "new-u")
        try await sut.updateHost(input)

        let saved = fakeDb.records[recID]
        XCTAssertEqual(saved?["name"] as? String, "new")
        XCTAssertEqual(saved?["hostname"] as? String, "new.example.com")
        XCTAssertEqual(saved?["port"] as? Int, 2222)
        XCTAssertEqual(saved?["username"] as? String, "new-u")
        XCTAssertEqual(fakeDb.recordFetchCallCount, 1)
        XCTAssertEqual(fakeDb.saveCallCount, 1)
    }

    func testUpdateHostMissingRecordThrowsHttp() async throws {
        // Record id not present in the fake — `record(for:)` throws
        // CKError.unknownItem, which CloudKitErrorMapping maps to .http(...).
        let input = RemoteHostUpdateInput(id: "missing")
        do {
            try await sut.updateHost(input)
            XCTFail("expected throw")
        } catch let e as ServerSyncError {
            if case .http = e { return }
            XCTFail("expected .http, got \(e)")
        }
    }
}
