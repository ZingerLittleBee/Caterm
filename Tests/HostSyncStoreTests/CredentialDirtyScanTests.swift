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
    private var keychain: KeychainStore!

    override func setUp() async throws {
        try await super.setUp()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-credscan-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        hostsURL = tmp.appendingPathComponent("hosts.json")
        keychain = KeychainStore(
            service: "test-\(UUID().uuidString)", accessGroup: nil
        )
        sessionStore = SessionStore(
            askpassPath: "/x", knownHostsCaterm: "/A", knownHostsUser: "/B",
            accessGroup: nil, hostsURL: hostsURL, keychain: keychain
        )
        fakeClient = FakeIncrementalHostSyncClient()
        // Empty snapshot isolates the credential push from metadata changes.
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
        try? keychain.deleteAll(prefix: "")
        try? FileManager.default.removeItem(at: hostsURL)
        try await super.tearDown()
    }

    func test_disabledState_doesNotQueueUpdateRemoteCredentials() async throws {
        _ = makeDirtyHostWithServerId()
        // prefsStore default state is .disabled — leave as-is.

        let sut = makeStore()
        try await sut.sync()

        XCTAssertTrue(
            fakeClient.pushCredentialCalls.isEmpty,
            "state=.disabled must not push credential material"
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

        XCTAssertTrue(
            fakeClient.pushCredentialCalls.isEmpty,
            "deleteCredentialsFromCloudInProgress != nil must suppress dirty pushes"
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
        try? keychain.set(
            account: "\(host.id.uuidString).password",
            secret: "test-secret"
        )
        return host
    }
}
