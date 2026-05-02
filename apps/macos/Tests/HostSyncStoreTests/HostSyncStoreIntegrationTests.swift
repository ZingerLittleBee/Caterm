import CredentialSyncStore
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
    var isolatedDefaults: UserDefaults!

    override func setUp() async throws {
        tmpHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-sync-\(UUID()).json")
        let kc = KeychainStore(service: "com.caterm.test.\(UUID().uuidString)",
                               accessGroup: nil)
        sessionStore = SessionStore(askpassPath: "/x", knownHostsCaterm: "/A",
                                     knownHostsUser: "/B", accessGroup: nil,
                                     hostsURL: tmpHostsURL, keychain: kc)
        fakeClient = FakeServerSyncClient()
        isolatedDefaults = UserDefaults(suiteName: "caterm-test-\(UUID().uuidString)")!
        let prefs = SyncPreferences(defaults: isolatedDefaults)
        sut = HostSyncStore(client: fakeClient,
                            sessionStore: sessionStore,
                            authSession: FakeAuthSession(isSignedIn: true),
                            preferences: prefs,
                            credentialSync: CredentialSyncPreferencesStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!),
                            userDefaults: isolatedDefaults)
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
/// Optional `listHostsDelay` lets tests simulate a hung sync (used by
/// chain-serialization and manual-vs-auto coordination tests in
/// HostSyncStoreAutoSyncTests). Default 0 preserves existing behavior.
///
/// Per-method error flags (`listHostsError`, `createHostError`,
/// `updateHostError`, `deleteHostError`) let tests distinguish "list
/// failed" from "list succeeded but apply[k] failed" — the partial-apply
/// branch in spec §4.2 that the older single `shouldThrow` flag could not
/// reach. Default nil = no error.
final class FakeServerSyncClient: IncrementalHostSyncClient, @unchecked Sendable {
    var listResult: [RemoteHost] = []
    var createResult = RemoteHostCreateOutput(id: "srv-default")
    var listCallCount = 0
    var createCallCount = 0
    var updateCallCount = 0
    var deleteCallCount = 0

    /// If > 0, listHosts() sleeps this many seconds before returning.
    /// Tests use this to keep a sync "in flight" while exercising
    /// chain serialization and manual-vs-auto coordination.
    var listHostsDelay: TimeInterval = 0
    /// Set true if the listHosts() sleep was interrupted by Task.cancel().
    var listHostsTaskWasCancelled = false
    /// Optional error thrown after `listHostsDelay` completes.
    var listHostsErrorAfterDelay: Error?
    /// Timestamps for ordering assertions in chain-serialization tests.
    var listHostsStartedAt: [Date] = []
    var listHostsFinishedAt: [Date] = []

    /// Per-method error flags. Set non-nil to make the corresponding
    /// method throw the given error before doing any work.
    var listHostsError: Error?
    var createHostError: Error?
    var updateHostError: Error?
    var deleteHostError: Error?

    // NEW: track which incremental client methods were called.
    var fetchHostChangesCallCount = 0
    var fetchHostSnapshotAndCheckpointCallCount = 0
    var commitHostCheckpointCallCount = 0
    var resetHostSyncStateCallCount = 0
    var ensureHostSubscriptionCallCount = 0
    var deleteHostSubscriptionCallCount = 0
    /// When true, preferredHostSyncMode returns .forceFull; else .incremental.
    var preferForceFull: Bool = true

    func listHosts() async throws -> [RemoteHost] {
        listCallCount += 1
        listHostsStartedAt.append(Date())
        if let err = listHostsError { throw err }
        if listHostsDelay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(listHostsDelay * 1_000_000_000))
            } catch {
                listHostsTaskWasCancelled = true
                throw error
            }
        }
        if let err = listHostsErrorAfterDelay { throw err }
        listHostsFinishedAt.append(Date())
        return listResult
    }
    func createHost(_ input: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput {
        createCallCount += 1
        if let err = createHostError { throw err }
        return createResult
    }
    func updateHost(_ input: RemoteHostUpdateInput) async throws {
        updateCallCount += 1
        if let err = updateHostError { throw err }
    }
    func deleteHost(id: String) async throws {
        deleteCallCount += 1
        if let err = deleteHostError { throw err }
    }

    func preferredHostSyncMode() async -> HostSyncMode {
        preferForceFull ? .forceFull : .incremental
    }

    func fetchHostChanges() async throws -> HostChangeBatch {
        fetchHostChangesCallCount += 1
        // For .incremental tests, default to no changes (callers can override
        // by setting listResult and toggling preferForceFull = false, but this
        // path isn't currently exercised by existing tests).
        return HostChangeBatch(
            changedHosts: [], deletedHostIDs: [],
            checkpoint: nil, tokenExpired: false, mode: .incremental
        )
    }

    func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch {
        fetchHostSnapshotAndCheckpointCallCount += 1
        // Mirror listHosts() semantics (delay, error, listResult) so existing
        // forceFull-driven tests work without modification.
        //
        // NOTE: listCallCount is intentionally also incremented here so legacy
        // `XCTAssertEqual(fakeClient.listCallCount, N)` assertions still pass
        // after the listHosts → fetchHostSnapshotAndCheckpoint migration.
        // For NEW assertions distinguishing the two paths, use
        // fetchHostSnapshotAndCheckpointCallCount (forceFull) or
        // fetchHostChangesCallCount (incremental) instead — listCallCount
        // is now overloaded and will be biased upward by every forceFull pass.
        listCallCount += 1
        listHostsStartedAt.append(Date())
        if let err = listHostsError { throw err }
        if listHostsDelay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(listHostsDelay * 1_000_000_000))
            } catch {
                listHostsTaskWasCancelled = true
                throw error
            }
        }
        if let err = listHostsErrorAfterDelay { throw err }
        listHostsFinishedAt.append(Date())
        return HostChangeBatch(
            changedHosts: listResult, deletedHostIDs: [],
            checkpoint: nil, tokenExpired: false, mode: .forceFull
        )
    }

    func commitHostCheckpoint(_ checkpoint: any HostSyncCheckpoint) async throws {
        commitHostCheckpointCallCount += 1
    }

    func resetHostSyncState() async {
        resetHostSyncStateCallCount += 1
    }

    func ensureHostSubscription() async throws {
        ensureHostSubscriptionCallCount += 1
    }

    func deleteHostSubscription() async throws {
        deleteHostSubscriptionCallCount += 1
    }
}
