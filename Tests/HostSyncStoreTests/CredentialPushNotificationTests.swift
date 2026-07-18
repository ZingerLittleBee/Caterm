import CredentialSyncStore
import CredentialSyncTypes
import KeychainStore
import ManagedKeyStore
import XCTest
@testable import HostSyncStore
@testable import ServerSyncClient
@testable import SessionStore
@testable import SSHCommandBuilder

/// Plan C / Task 15 — low-latency push notification observer test.
///
/// `SessionStore.setHostCredentialMaterial(...)` posts
/// `Notification.Name.catermHostCredentialMaterialChanged` after persisting
/// `hosts.json` with `credentialMaterialDirty=true`. `HostSyncStore` observes
/// this notification and schedules an auto-sync cycle so the dirty-scan can
/// immediately queue `.updateRemoteCredentials` and the executor pushes the
/// new ciphertext.
///
/// The realistic flow is: user changes a credential → SessionStore sets
/// dirty=true AND posts the notification. This test mirrors that: dirty bit
/// is true on the host before the notification fires, then we assert the
/// resulting cycle pushes the credential blob.
@MainActor
final class CredentialPushNotificationTests: XCTestCase {
    private var sessionStore: SessionStore!
    private var fakeClient: FakeIncrementalHostSyncClient!
    private var prefsStore: CredentialSyncPreferencesStore!
    private var syncPrefs: SyncPreferences!
    private var isolatedDefaults: UserDefaults!
    private var hostsURL: URL!
    private var masterKeyStore: KeychainSyncMasterKeyStore!
    private var generatedKeyID: String?
    private var managedKeyStore: ManagedKeyStore!
    private var managedKeyRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-credpush-notif-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        hostsURL = tmp.appendingPathComponent("hosts.json")
        let keychain = KeychainStore(
            service: "test-\(UUID().uuidString)", accessGroup: nil
        )
		managedKeyRoot = tmp.appendingPathComponent("managed-keys", isDirectory: true)
		managedKeyStore = ManagedKeyStore(rootURL: managedKeyRoot)
        sessionStore = SessionStore(
            askpassPath: "/x", knownHostsCaterm: "/A", knownHostsUser: "/B",
			accessGroup: nil, hostsURL: hostsURL, keychain: keychain,
			managedKeyStore: managedKeyStore
        )
        fakeClient = FakeIncrementalHostSyncClient()
        fakeClient.fetchSnapshotResult = HostChangeBatch(
            changedHosts: [], deletedHostIDs: [],
            checkpoint: nil, tokenExpired: false, mode: .forceFull
        )
        isolatedDefaults = UserDefaults(suiteName: "caterm-credpush-notif-\(UUID().uuidString)")!
        syncPrefs = SyncPreferences(defaults: isolatedDefaults)
        prefsStore = CredentialSyncPreferencesStore(
            defaults: UserDefaults(suiteName: "creds-notif-\(UUID().uuidString)")!
        )
        masterKeyStore = KeychainSyncMasterKeyStore(
            service: "test-\(UUID().uuidString)",
            synchronizable: false
        )
    }

    override func tearDown() async throws {
        if let id = generatedKeyID {
            await masterKeyStore.remove(keyID: id)
            generatedKeyID = nil
        }
        try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent())
        try await super.tearDown()
    }

    func test_notificationTriggersImmediateSyncCycle() async throws {
        // Setup mirrors test_executor_serverIdPresent_pushesAndClearsDirty:
        // host with serverId, prefs .enabled, password secret in keychain,
        // master key staged in keychain, dirty=true so the dirty-scan queues
        // `.updateRemoteCredentials`, and snapshot mirrors local so the
        // reconciler emits no metadata op.
        prefsStore.mutate { $0.state = .enabled }
        let host = SSHHost(
            name: "dirty",
            hostname: "h",
            port: 22,
            username: "u",
            credential: .password,
            credentialMaterialDirty: true
        )
        try sessionStore.addHost(host)
        try sessionStore.setServerId("rec-1", for: host.id)
        try sessionStore.setHostSecret("p1", hostId: host.id, kind: .password)
        try await stageMasterKey()
        seedSnapshotMatchingLocal(serverId: "rec-1", host: host)

        let sut = makeStore()
        // Hold a strong reference to the store so the observer survives the
        // poll-wait window. Without this the compiler may otherwise treat
        // `sut` as transient under release optimisation.
        _ = sut

        // Post the notification. SessionStore.setHostCredentialMaterial
        // includes userInfo[hostId] — we mirror that even though our observer
        // does not currently read it (future-proofs the test against changes
        // to the notification payload contract).
        NotificationCenter.default.post(
            name: .catermHostCredentialMaterialChanged,
            object: nil,
            userInfo: [CatermHostCredentialMaterialChangedKeys.hostId: host.id]
        )

        // The observer dispatches via scheduleAutoSync → startSync → an
        // unstructured Task. Poll until the executor records the push call,
        // up to 2 seconds (well under any realistic CI timeout while
        // tolerating scheduler jitter).
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && fakeClient.pushCredentialCalls.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        XCTAssertEqual(
            fakeClient.pushCredentialCalls.count, 1,
            "notification must trigger exactly one credential push within the deadline"
        )
        let call = fakeClient.pushCredentialCalls[0]
        XCTAssertEqual(call.serverId, "rec-1")
        XCTAssertEqual(call.blob.state, .payload)
        XCTAssertNotNil(call.blob.passwordCiphertext)
    }

    // MARK: - Helpers

    private func makeStore() -> HostSyncStore {
        HostSyncStore(
            client: fakeClient,
            sessionStore: sessionStore,
            authSession: FakeAuthSession(isSignedIn: true),
            preferences: syncPrefs,
            credentialSync: prefsStore,
            masterKeyStore: masterKeyStore,
            debounceInterval: 0.05,
            userDefaults: isolatedDefaults
        )
    }

    private func stageMasterKey() async throws {
        let (id, _) = try await masterKeyStore.generate()
        generatedKeyID = id
    }

    private func makeRemoteHostMatchingLocal(serverId: String, host: SSHHost) -> RemoteHost {
        let live = sessionStore.hosts.first { $0.id == host.id } ?? host
        return RemoteHost(
            id: serverId,
            name: live.name,
            hostname: live.hostname,
            port: live.port,
            username: live.username,
            authType: "password",
            createdAt: live.createdAt,
            updatedAt: live.updatedAt
        )
    }

    private func seedSnapshotMatchingLocal(serverId: String, host: SSHHost) {
        let remote = makeRemoteHostMatchingLocal(serverId: serverId, host: host)
        fakeClient.fetchSnapshotResult = HostChangeBatch(
            changedHosts: [remote], deletedHostIDs: [],
            checkpoint: nil, tokenExpired: false, mode: .forceFull
        )
    }
}
