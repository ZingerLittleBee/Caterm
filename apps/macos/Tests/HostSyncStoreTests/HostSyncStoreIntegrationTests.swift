import XCTest
@testable import HostSyncStore
@testable import SessionStore
@testable import SSHCommandBuilder
@testable import ServerSyncClient
@testable import KeychainStore

@MainActor
final class HostSyncStoreIntegrationTests: XCTestCase {
    var sut: HostSyncStore!
    var fakeClient: FakeServerSyncClient!
    var sessionStore: SessionStore!
    var tmpHostsURL: URL!

    override func setUp() async throws {
        tmpHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-sync-\(UUID()).json")
        let kc = KeychainStore(service: "com.caterm.test.\(UUID().uuidString)",
                               accessGroup: nil)
        sessionStore = SessionStore(askpassPath: "/x", knownHostsCaterm: "/A",
                                     knownHostsUser: "/B", accessGroup: nil,
                                     hostsURL: tmpHostsURL, keychain: kc)
        fakeClient = FakeServerSyncClient()
        sut = HostSyncStore(client: fakeClient, sessionStore: sessionStore)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpHostsURL)
    }

    func testFirstSyncUploadsLocalUnsyncedHosts() async throws {
        let h = SSHHost(name: "alpha", hostname: "x", username: "u", credential: .agent)
        try sessionStore.addHost(h)
        fakeClient.listResult = []
        fakeClient.createResult = RemoteHostCreateOutput(id: "srv-1")

        try await sut.sync()

        XCTAssertEqual(fakeClient.createCallCount, 1)
        let updated = sessionStore.hosts.first { $0.id == h.id }
        XCTAssertEqual(updated?.serverId, "srv-1")
    }

    func testFirstSyncDownloadsRemoteOnlyHosts() async throws {
        fakeClient.listResult = [
            RemoteHost(id: "srv-1", name: "alpha", hostname: "x", port: 22,
                       username: "u", authType: "key",
                       createdAt: Date(), updatedAt: Date())
        ]

        try await sut.sync()

        XCTAssertEqual(sessionStore.hosts.count, 1)
        XCTAssertEqual(sessionStore.hosts[0].name, "alpha")
        XCTAssertEqual(sessionStore.hosts[0].serverId, "srv-1")
    }

    func testNeedsCredentialSetupForRemotePulledHost() async throws {
        // A host pulled from server has no CredentialSource overlay yet.
        // Per spec §7.1.2, that host should report needsCredentialSetup=true.
        fakeClient.listResult = [
            RemoteHost(id: "srv-1", name: "alpha", hostname: "x", port: 22,
                       username: "u", authType: "key",
                       createdAt: Date(), updatedAt: Date())
        ]
        try await sut.sync()
        let pulled = sessionStore.hosts[0]
        XCTAssertTrue(sessionStore.needsCredentialSetup(pulled))
    }

    func testSyncedThenRemoteDeletedRemovesLocal() async throws {
        var h = SSHHost(name: "alpha", hostname: "x", username: "u", credential: .agent)
        h.serverId = "srv-1"
        try sessionStore.addHost(h)
        fakeClient.listResult = []  // server lost it (other device deleted)

        try await sut.sync()

        XCTAssertTrue(sessionStore.hosts.isEmpty)
    }

    func testLocalOnlyAgentHostDoesNotNeedCredentialSetup() throws {
        let h = SSHHost(name: "alpha", hostname: "x", username: "u", credential: .agent)
        try sessionStore.addHost(h)
        XCTAssertFalse(sessionStore.needsCredentialSetup(h))
    }
}

/// In-memory fake for tests. Records calls; returns canned responses.
final class FakeServerSyncClient: ServerSyncClient, @unchecked Sendable {
    var listResult: [RemoteHost] = []
    var createResult = RemoteHostCreateOutput(id: "srv-default")
    var listCallCount = 0
    var createCallCount = 0
    var updateCallCount = 0
    var deleteCallCount = 0

    func listHosts() async throws -> [RemoteHost] {
        listCallCount += 1; return listResult
    }
    func createHost(_ input: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput {
        createCallCount += 1; return createResult
    }
    func updateHost(_ input: RemoteHostUpdateInput) async throws {
        updateCallCount += 1
    }
    func deleteHost(id: String) async throws {
        deleteCallCount += 1
    }
}
