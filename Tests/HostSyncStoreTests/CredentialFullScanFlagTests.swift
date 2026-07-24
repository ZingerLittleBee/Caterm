import CredentialSyncStore
import KeychainStore
import XCTest
@testable import HostSyncStore
@testable import ServerSyncClient
@testable import SessionStore
@testable import SSHCommandBuilder

/// Plan C / Task 18 — `HostSyncStore` must consult
/// `credentialSync.prefs.credentialsNeedFullScan` when the requested mode is
/// `.auto`, force a `.forceFull` pass when it's set, and clear the flag only
/// after a successful checkpoint commit.
@MainActor
final class CredentialFullScanFlagTests: XCTestCase {
    private var sessionStore: SessionStore!
    private var fakeClient: FakeIncrementalHostSyncClient!
    private var prefsStore: CredentialSyncPreferencesStore!
    private var syncPrefs: SyncPreferences!
    private var isolatedDefaults: UserDefaults!
    private var hostsURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-fullscan-flag-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        hostsURL = tmp.appendingPathComponent("hosts.json")
        let keychain = KeychainStore(
            service: "test-\(UUID().uuidString)", accessGroup: nil
        )
        sessionStore = SessionStore(
            askpassPath: "/x", knownHostsCaterm: "/A", knownHostsUser: "/B",
            accessGroup: nil, hostsURL: hostsURL, keychain: keychain
        )
        fakeClient = FakeIncrementalHostSyncClient()
        // Differentiate `.auto` selection: without the patch, auto would
        // resolve to .incremental here; with the patch + flag, it should
        // upgrade to .forceFull.
        fakeClient.preferredModeOverride = .incremental
        isolatedDefaults = UserDefaults(suiteName: "caterm-fullscan-flag-\(UUID().uuidString)")!
        syncPrefs = SyncPreferences(defaults: isolatedDefaults)
        prefsStore = CredentialSyncPreferencesStore(
            defaults: UserDefaults(suiteName: "creds-\(UUID().uuidString)")!
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: hostsURL)
        try await super.tearDown()
    }

    func test_flagSet_forcesForceFull_thenClears() async throws {
        prefsStore.mutate { $0.credentialsNeedFullScan = true }
        fakeClient.fetchSnapshotResult = HostChangeBatch(
            changedHosts: [], deletedHostIDs: [],
            checkpoint: FakeCheckpoint(id: UUID()),
            tokenExpired: false, mode: .forceFull
        )

        let sut = makeStore()
        try await sut.sync()

        XCTAssertEqual(
            fakeClient.fetchModes, [.forceFull],
            "credentialsNeedFullScan=true must upgrade .auto → .forceFull"
        )
        XCTAssertEqual(
            fakeClient.commitCalls.count, 1,
            "successful cycle should land a checkpoint commit"
        )
        XCTAssertFalse(
            prefsStore.prefs.credentialsNeedFullScan,
            "flag must be cleared after a successful commit"
        )
    }

    func test_cycleThrowsBeforeCheckpoint_flagPreserved() async throws {
        prefsStore.mutate { $0.credentialsNeedFullScan = true }

        // Local-only host (no serverId) → reconciler emits .createRemote →
        // fake's createHost throws → cycle aborts before commit.
        let host = SSHHost(
            name: "local-only", hostname: "h", port: 22, username: "u",
            credential: .password
        )
        try await sessionStore.addHost(host)

        fakeClient.fetchSnapshotResult = HostChangeBatch(
            changedHosts: [], deletedHostIDs: [],
            checkpoint: FakeCheckpoint(id: UUID()),
            tokenExpired: false, mode: .forceFull
        )
        fakeClient.createHostError = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "createHost throws"]
        )

        let sut = makeStore()
        do {
            try await sut.sync()
            XCTFail("expected sync to throw when createHost errors")
        } catch {
            // expected
        }

        XCTAssertEqual(
            fakeClient.fetchModes, [.forceFull],
            "fetch should still have run as forceFull"
        )
        XCTAssertTrue(
            fakeClient.commitCalls.isEmpty,
            "commit must NOT have been reached"
        )
        XCTAssertTrue(
            prefsStore.prefs.credentialsNeedFullScan,
            "flag must stay true so the next cycle still runs forceFull"
        )
    }

    // MARK: - Helpers

    private func makeStore() -> HostSyncStore {
        HostSyncStore(
            client: fakeClient,
            sessionStore: sessionStore,
            authSession: FakeAuthSession(isSignedIn: true),
            preferences: syncPrefs,
            credentialSync: prefsStore,
            debounceInterval: 0.05,
            userDefaults: isolatedDefaults
        )
    }
}
