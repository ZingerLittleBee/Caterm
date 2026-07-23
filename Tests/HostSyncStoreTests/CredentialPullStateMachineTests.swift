import CredentialSyncStore
import CredentialSyncTypes
import KeychainStore
import ManagedKeyStore
import XCTest
@testable import HostSyncStore
@testable import ServerSyncClient
@testable import SessionStore
@testable import SSHCommandBuilder

/// Plan C / Task 16 — pull-side credential state machine.
///
/// `applyCredentialBlobOnPull(localHostId:remote:blob:)` dispatches a
/// freshly-fetched `CredentialBlob` based on `prefs.state`. These tests
/// cover the four state arms and the stale-revision drop.
///
/// **Reconciler-emit gap:** `HostSyncReconciler` compares metadata only;
/// a remote whose only change is the credential blob produces NO op, so
/// `applyCredentialBlobOnPull` is never invoked for it. To make these
/// tests deterministic, every test seeds a remote with `updatedAt`
/// strictly newer than the local — that forces the reconciler to emit
/// `.updateLocal`, which carries the blob through. The "credential-only"
/// case is a real spec gap deferred to a future task.
@MainActor
final class CredentialPullStateMachineTests: XCTestCase {
    private var sessionStore: SessionStore!
    private var fakeClient: FakeIncrementalHostSyncClient!
    private var prefsStore: CredentialSyncPreferencesStore!
    private var syncPrefs: SyncPreferences!
    private var isolatedDefaults: UserDefaults!
    private var hostsURL: URL!
    private var keychain: KeychainStore!
    private var masterKeyStore: KeychainSyncMasterKeyStore!
    private var managedKeyStore: ManagedKeyStore!
    private var managedKeyRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-credpull-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        hostsURL = tmp.appendingPathComponent("hosts.json")
        keychain = KeychainStore(
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
        isolatedDefaults = UserDefaults(suiteName: "caterm-credpull-\(UUID().uuidString)")!
        syncPrefs = SyncPreferences(defaults: isolatedDefaults)
        prefsStore = CredentialSyncPreferencesStore(
            defaults: UserDefaults(suiteName: "creds-pull-\(UUID().uuidString)")!
        )
        masterKeyStore = KeychainSyncMasterKeyStore(
            service: "test-\(UUID().uuidString)",
            synchronizable: false
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent())
        try await super.tearDown()
    }

    // MARK: - Tests

    func test_disabled_doesNotApplyPayload_doesNotAdvanceLastApplied() async throws {
        prefsStore.mutate { $0.state = .disabled }
        let host = await seedLocalHost(serverId: "rec-1")
        let remote = makeNewerRemote(serverId: "rec-1", host: host)
        let blob = CredentialBlob(
            state: .payload, revision: 7, keyID: "k1",
            passwordCiphertext: Data([0x01])
        )
        seedBatch(remote: remote, blob: blob)

        let sut = makeStore()
        try await sut.sync()

        XCTAssertNil(
            prefsStore.prefs.lastAppliedRevision[host.id],
            "disabled must NOT advance lastAppliedRevision"
        )
        XCTAssertEqual(prefsStore.prefs.state, .disabled,
                       "disabled state must remain unchanged")
        XCTAssertNil(
            try? keychain.get(account: "\(host.id.uuidString).password"),
            "disabled must not write credentials to the keychain"
        )
    }

    func test_pausedByRemote_payloadHigherThanTombstone_bumpsTombstoneRev() async throws {
        prefsStore.mutate { $0.state = .pausedByRemote(seenTombstoneRevision: 5) }
        let host = await seedLocalHost(serverId: "rec-1")
        let remote = makeNewerRemote(serverId: "rec-1", host: host)
        let blob = CredentialBlob(
            state: .payload, revision: 9, keyID: "k1",
            passwordCiphertext: Data([0x02])
        )
        seedBatch(remote: remote, blob: blob)

        let sut = makeStore()
        try await sut.sync()

        XCTAssertEqual(
            prefsStore.prefs.state, .pausedByRemote(seenTombstoneRevision: 9),
            "payload with revision > seenTombstoneRev must bump the marker"
        )
        XCTAssertNil(
            prefsStore.prefs.lastAppliedRevision[host.id],
            "paused must NOT advance lastAppliedRevision"
        )
    }

    func test_waitingForKey_payload_setsObservedKeyID() async throws {
        prefsStore.mutate { $0.state = .waitingForKey(observedKeyID: nil) }
        let host = await seedLocalHost(serverId: "rec-1")
        let remote = makeNewerRemote(serverId: "rec-1", host: host)
        let blob = CredentialBlob(
            state: .payload, revision: 3, keyID: "key-A",
            passwordCiphertext: Data([0x03])
        )
        seedBatch(remote: remote, blob: blob)

        let sut = makeStore()
        try await sut.sync()

        XCTAssertEqual(
            prefsStore.prefs.state, .waitingForKey(observedKeyID: "key-A"),
            "payload while waitingForKey must update observedKeyID"
        )
        XCTAssertNil(
            prefsStore.prefs.lastAppliedRevision[host.id],
            "waitingForKey must NOT advance lastAppliedRevision"
        )
    }

    func test_waitingForKey_tombstone_transitionsToPaused() async throws {
        prefsStore.mutate { $0.state = .waitingForKey(observedKeyID: "key-A") }
        let host = await seedLocalHost(serverId: "rec-1")
        let remote = makeNewerRemote(serverId: "rec-1", host: host)
        let blob = CredentialBlob(state: .tombstone, revision: 11, keyID: nil)
        seedBatch(remote: remote, blob: blob)

        let sut = makeStore()
        try await sut.sync()

        XCTAssertEqual(
            prefsStore.prefs.state, .pausedByRemote(seenTombstoneRevision: 11),
            "tombstone while waitingForKey must transition to pausedByRemote"
        )
        XCTAssertNil(
            prefsStore.prefs.lastAppliedRevision[host.id],
            "waitingForKey→pausedByRemote does NOT advance lastAppliedRevision"
        )
    }

    func test_enabled_tombstone_transitionsToPaused_doesNotTouchKeychain() async throws {
        prefsStore.mutate { $0.state = .enabled }
        let host = await seedLocalHost(serverId: "rec-1")
        // Pre-stage the host in the payload-tracking set — the observed
        // tombstone must remove it so the UI count doesn't lie.
        prefsStore.mutate { $0.hostsWithCloudPayload = [host.id] }
        let remote = makeNewerRemote(serverId: "rec-1", host: host)
        let blob = CredentialBlob(state: .tombstone, revision: 13, keyID: nil)
        seedBatch(remote: remote, blob: blob)

        let sut = makeStore()
        try await sut.sync()

        XCTAssertEqual(
            prefsStore.prefs.state, .pausedByRemote(seenTombstoneRevision: 13),
            "tombstone while enabled must transition to pausedByRemote"
        )
        XCTAssertEqual(
            prefsStore.prefs.lastAppliedRevision[host.id], 13,
            "enabled+tombstone advances lastAppliedRevision so we don't replay"
        )
        XCTAssertNil(
            try? keychain.get(account: "\(host.id.uuidString).password"),
            "tombstone in enabled must not touch keychain credentials"
        )
        XCTAssertFalse(
            prefsStore.prefs.hostsWithCloudPayload.contains(host.id),
            "observed tombstone must drop the host from the payload-tracking set"
        )
    }

    func test_enabled_payload_decryptsAndAppliesViaSessionStore() async throws {
        // Plan C / Task 17 — `.enabled.payload` actually decrypts ciphertext
        // and persists via SessionStore. The public outcome is the password
        // round-tripping to the keychain and revision state advancing.
        prefsStore.mutate { $0.state = .enabled }
        let host = await seedLocalHost(serverId: "rec-1")

        let resolved = try await masterKeyStore.generate()
        let key = resolved.key
        let keyID = resolved.keyID
        let serverId = "rec-1"
        let revision: Int64 = 4
        let pwCt = try EnvelopeCrypto.seal(
            Data("p1".utf8), key: key,
            aad: EnvelopeCrypto.aad(serverId: serverId, fieldKind: .password, revision: revision)
        )
        let remote = makeNewerRemote(serverId: serverId, host: host)
        let blob = CredentialBlob(
            state: .payload, revision: revision, keyID: keyID,
            cryptoVersion: Int64(EnvelopeCrypto.schemaVersion),
            passwordCiphertext: pwCt
        )
        seedBatch(remote: remote, blob: blob)

        let sut = makeStore()
        try await sut.sync()

        XCTAssertEqual(
            try keychain.get(account: "\(host.id.uuidString).password"), "p1",
            "decryptAndApply must persist the decrypted password to the keychain"
        )
        XCTAssertEqual(
            prefsStore.prefs.lastAppliedRevision[host.id], revision,
            "successful apply must bump lastAppliedRevision"
        )
        XCTAssertTrue(
            prefsStore.prefs.hostsWithCloudPayload.contains(host.id),
            "successful payload decrypt must add the host to the payload-tracking set"
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
            masterKeyStore: masterKeyStore,
            debounceInterval: 0.05,
            userDefaults: isolatedDefaults
        )
    }

    /// Seed a local host already-synced under `serverId`. Its `updatedAt`
    /// is `Date.distantPast` so any reasonable remote `updatedAt` will be
    /// strictly newer, forcing the reconciler to emit `.updateLocal`.
    @discardableResult
    private func seedLocalHost(serverId: String) async -> SSHHost {
        let host = SSHHost(
            id: UUID(),
            serverId: serverId,
            name: "h",
            hostname: "host.example",
            port: 22,
            username: "u",
            credential: .password,
            createdAt: Date.distantPast,
            updatedAt: Date.distantPast
        )
        try? await sessionStore.addHost(host)
        return host
    }

    /// Build a `RemoteHost` with `updatedAt = now` so the reconciler emits
    /// `.updateLocal` for the seeded local host.
    private func makeNewerRemote(serverId: String, host: SSHHost) -> RemoteHost {
        RemoteHost(
            id: serverId,
            name: host.name,
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            authType: "password",
            createdAt: host.createdAt,
            updatedAt: Date()
        )
    }

    /// Seed `fakeClient` with a snapshot containing one remote and an
    /// associated credential blob in the side-table.
    private func seedBatch(remote: RemoteHost, blob: CredentialBlob) {
        fakeClient.fetchSnapshotResult = HostChangeBatch(
            changedHosts: [remote],
            deletedHostIDs: [],
            credentialBlobsByServerId: [remote.id: blob],
            checkpoint: nil,
            tokenExpired: false,
            mode: .forceFull
        )
    }
}
