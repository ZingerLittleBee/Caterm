import CredentialSyncStore
import KeychainStore
import XCTest
@testable import HostSyncStore
@testable import ServerSyncClient
@testable import SessionStore
@testable import SSHCommandBuilder

@MainActor
final class CredentialDirtyScanTests: XCTestCase {
    private var sessionStore: SessionStore!
    private var fakeClient: FakeIncrementalHostSyncClient!
    private var prefsStore: CredentialSyncPreferencesStore!
    private var syncPrefs: SyncPreferences!
    private var isolatedDefaults: UserDefaults!
    private var hostsURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-credscan-\(UUID().uuidString)")
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
        // Empty snapshot — reconciler emits no ops, so the only ops we can
        // observe in lastAppliedOpsForTesting come from the dirty scan.
        fakeClient.fetchSnapshotResult = HostChangeBatch(
            changedHosts: [], deletedHostIDs: [],
            checkpoint: nil, tokenExpired: false, mode: .forceFull
        )
        isolatedDefaults = UserDefaults(suiteName: "caterm-credscan-\(UUID().uuidString)")!
        syncPrefs = SyncPreferences(defaults: isolatedDefaults)
        prefsStore = CredentialSyncPreferencesStore(
            defaults: UserDefaults(suiteName: "creds-\(UUID().uuidString)")!
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: hostsURL)
        try await super.tearDown()
    }

    func test_dirtyHostInEnabled_queuesUpdateRemoteCredentials_afterReconcilerOps() async throws {
        let host = makeDirtyHostWithServerId()
        prefsStore.mutate { $0.state = .enabled }

        let sut = makeStore()
        try await sut.sync()

        XCTAssertTrue(
            sut.lastAppliedOpsForTesting.contains(.updateRemoteCredentials(localHostId: host.id)),
            "Dirty host with state=.enabled must produce a .updateRemoteCredentials op"
        )
    }

    func test_disabledState_doesNotQueueUpdateRemoteCredentials() async throws {
        _ = makeDirtyHostWithServerId()
        // prefsStore default state is .disabled — leave as-is.

        let sut = makeStore()
        try await sut.sync()

        XCTAssertFalse(
            sut.lastAppliedOpsForTesting.contains(where: { op in
                if case .updateRemoteCredentials = op { return true }
                return false
            }),
            "state=.disabled must not queue .updateRemoteCredentials"
        )
    }

    func test_deletionInProgress_doesNotQueueUpdateRemoteCredentials() async throws {
        _ = makeDirtyHostWithServerId()
        prefsStore.mutate {
            $0.state = .enabled
            $0.deleteCredentialsFromCloudInProgress = DeletionProgress(pendingLocalHostIds: [])
        }

        let sut = makeStore()
        try await sut.sync()

        XCTAssertFalse(
            sut.lastAppliedOpsForTesting.contains(where: { op in
                if case .updateRemoteCredentials = op { return true }
                return false
            }),
            "deleteCredentialsFromCloudInProgress != nil must suppress the dirty-scan op"
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

    @discardableResult
    private func makeDirtyHostWithServerId() -> SSHHost {
        let host = SSHHost(
            name: "dirty",
            hostname: "h",
            port: 22,
            username: "u",
            credential: .password,
            credentialMaterialDirty: true
        )
        try? sessionStore.addHost(host)
        try? sessionStore.setServerId("rec-1", for: host.id)
        return host
    }
}
