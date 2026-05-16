import CredentialSyncStore
import CredentialSyncTypes
import KeychainStore
import ManagedKeyStore
import XCTest
@testable import HostSyncStore
@testable import ServerSyncClient
@testable import SessionStore
@testable import SSHCommandBuilder

/// Plan C / Task 25 — end-to-end push/pull integration.
///
/// Two simulated Macs share one master key (via a shared `service` string on
/// `KeychainSyncMasterKeyStore`) but have separate `SessionStore` and
/// `ManagedKeyStore` instances. Mac A pushes an encrypted credential through
/// its fake client; the captured ciphertext is fed verbatim into Mac B's
/// fetch result so Mac B's pull pipeline decrypts and applies it locally.
///
/// This validates the AAD/seal/open round-trip, master-key resolution by
/// `keyID`, and pull-side `applyCredentialBlobOnPull` integration.
@MainActor
final class EndToEndPushPullTests: XCTestCase {
    private var sharedMasterKeyService: String!

    override func setUp() async throws {
        try await super.setUp()
        sharedMasterKeyService = "e2e-master-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        // Cleanup: remove the shared keychain item by re-deriving keyID via
        // loadAny(). Tests use unique service strings so leaks across tests
        // are bounded to a single test's run; this final remove keeps the
        // system keychain tidy.
        let store = KeychainSyncMasterKeyStore(
            service: sharedMasterKeyService, synchronizable: false
        )
        if let pair = await store.loadAny() {
            await store.remove(keyID: pair.keyID)
        }
        try await super.tearDown()
    }

    // MARK: - Tests

    func test_macA_pushesPasswordCredential_macBDecryptsAndStores() async throws {
        let mac = try await makeTwoMacs()

        // ─── Mac A: enable, add host with serverId pre-assigned, push ───
        // Pre-assigning the serverId mirrors what other Plan C executor
        // tests do — keeps the cycle's only op `.updateRemoteCredentials`,
        // so the test focuses on encrypt/seal rather than the createRemote
        // round-trip already covered elsewhere.
        mac.a.prefs.mutate { $0.state = .enabled }
        let aHostId = UUID()
        let host = SSHHost(
            id: aHostId,
            name: "alpha", hostname: "a.example", port: 22,
            username: "u", credential: .password,
            createdAt: Date.distantPast, updatedAt: Date.distantPast
        )
        try mac.a.session.addHost(host)
        try mac.a.session.setServerId("rec-A1", for: aHostId)
        try mac.a.session.setHostCredentialMaterial(
            secrets: HostSecrets(password: Data("p1".utf8)),
            credentialSource: .password,
            for: aHostId
        )

        // Snapshot mirrors the local row so the reconciler emits no
        // metadata op; the only op is the dirty-scan-driven push.
        // Both `fetchSnapshotResult` and `fetchSnapshotResultRetry` return
        // the same matching batch — `setHostCredentialMaterial` posts a
        // notification that triggers an immediate (un-debounced)
        // `scheduleAutoSync`, so by the time the test's manual `sync()`
        // runs the first fetch slot may already be consumed.
        let aLive = mac.a.session.hosts.first { $0.id == aHostId }!
        let aMatchingBatch = HostChangeBatch(
            changedHosts: [
                RemoteHost(
                    id: "rec-A1", name: aLive.name, hostname: aLive.hostname,
                    port: aLive.port, username: aLive.username,
                    authType: "password",
                    createdAt: aLive.createdAt, updatedAt: aLive.updatedAt
                ),
            ],
            deletedHostIDs: [],
            checkpoint: FakeCheckpoint(id: UUID()),
            tokenExpired: false, mode: .forceFull
        )
        mac.a.fake.fetchSnapshotResult = aMatchingBatch
        mac.a.fake.fetchSnapshotResultRetry = aMatchingBatch

        try await mac.a.store.sync()

        // Push captured exactly one credential blob with non-nil keyID.
        XCTAssertEqual(mac.a.fake.pushCredentialCalls.count, 1)
        let pushed = mac.a.fake.pushCredentialCalls[0]
        XCTAssertEqual(pushed.blob.state, .payload)
        XCTAssertNotNil(pushed.blob.keyID)
        XCTAssertNotNil(pushed.blob.passwordCiphertext)
        let serverId = pushed.serverId

        // ─── Mac B: pre-seed local mirror + run pull ────────────────────
        // Replicate the "metadata sync first" flow: Mac B already knows the
        // host (created by reconciler) but hasn't applied its credential
        // yet. We seed a local host with the same serverId so the
        // reconciler emits `.updateLocal` carrying the blob.
        let bHostId = UUID()
        let bHost = SSHHost(
            id: bHostId, serverId: serverId,
            name: host.name, hostname: host.hostname,
            port: host.port, username: host.username,
            credential: .password,
            createdAt: Date.distantPast, updatedAt: Date.distantPast
        )
        try mac.b.session.addHost(bHost)
        mac.b.prefs.mutate { $0.state = .enabled }

        let remote = RemoteHost(
            id: serverId,
            name: host.name, hostname: host.hostname,
            port: host.port, username: host.username,
            authType: "password",
            createdAt: Date.distantPast,
            updatedAt: Date()  // newer → reconciler emits .updateLocal
        )
        // Stage on both fetch slots — see Mac A comment above. Mac A's
        // `setHostCredentialMaterial` posts a process-wide notification
        // that triggers Mac B's HostSyncStore observer too, consuming the
        // first fetch slot.
        let bMatchingBatch = HostChangeBatch(
            changedHosts: [remote],
            deletedHostIDs: [],
            credentialBlobsByServerId: [serverId: pushed.blob],
            checkpoint: FakeCheckpoint(id: UUID()),
            tokenExpired: false, mode: .forceFull
        )
        mac.b.fake.fetchSnapshotResult = bMatchingBatch
        mac.b.fake.fetchSnapshotResultRetry = bMatchingBatch

        try await mac.b.store.sync()

        // Mac B has the password in its keychain.
        XCTAssertEqual(
            try mac.b.keychain.get(account: "\(bHostId.uuidString).password"),
            "p1",
            "Mac B should have decrypted Mac A's password"
        )
        XCTAssertEqual(
            mac.b.prefs.prefs.lastAppliedRevision[bHostId], pushed.blob.revision,
            "lastAppliedRevision must match the pushed revision"
        )
    }

    func test_macA_pushesKeyfileCredential_macBDecryptsToManagedKeyPath() async throws {
        let mac = try await makeTwoMacs()

        // ─── Mac A: enable, add keyfile host with private-key bytes ─────
        mac.a.prefs.mutate { $0.state = .enabled }
        let aHostId = UUID()
        let host = SSHHost(
            id: aHostId,
            name: "beta", hostname: "b.example", port: 22,
            username: "u",
            credential: .keyFile(keyPath: "/tmp/ignored", hasPassphrase: true),
            createdAt: Date.distantPast, updatedAt: Date.distantPast
        )
        try mac.a.session.addHost(host)
        try mac.a.session.setServerId("rec-A2", for: aHostId)

        // Write managed key bytes via Mac A's ManagedKeyStore so the
        // dirty-scan/push path can read them.
        let pkBytes = Data("FAKE-RSA-PRIVATE-KEY-CONTENT".utf8)
        let url = try await mac.a.managed.write(hostId: aHostId, bytes: pkBytes)
        try mac.a.session.setHostCredentialMaterial(
            secrets: HostSecrets(passphrase: Data("pp".utf8)),
            credentialSource: .keyFile(keyPath: url.path, hasPassphrase: true),
            for: aHostId
        )

        let aLive = mac.a.session.hosts.first { $0.id == aHostId }!
        let aMatchingBatch = HostChangeBatch(
            changedHosts: [
                RemoteHost(
                    id: "rec-A2", name: aLive.name, hostname: aLive.hostname,
                    port: aLive.port, username: aLive.username,
                    authType: "key",
                    createdAt: aLive.createdAt, updatedAt: aLive.updatedAt
                ),
            ],
            deletedHostIDs: [],
            checkpoint: FakeCheckpoint(id: UUID()),
            tokenExpired: false, mode: .forceFull
        )
        mac.a.fake.fetchSnapshotResult = aMatchingBatch
        mac.a.fake.fetchSnapshotResultRetry = aMatchingBatch

        try await mac.a.store.sync()

        XCTAssertEqual(mac.a.fake.pushCredentialCalls.count, 1)
        let pushed = mac.a.fake.pushCredentialCalls[0]
        XCTAssertNotNil(pushed.blob.passphraseCiphertext)
        XCTAssertNotNil(pushed.blob.privateKeyCiphertext)
        let serverId = pushed.serverId

        // ─── Mac B: pull ────────────────────────────────────────────────
        let bHostId = UUID()
        let bHost = SSHHost(
            id: bHostId, serverId: serverId,
            name: host.name, hostname: host.hostname,
            port: host.port, username: host.username,
            credential: .keyFile(keyPath: "/tmp/placeholder", hasPassphrase: true),
            createdAt: Date.distantPast, updatedAt: Date.distantPast
        )
        try mac.b.session.addHost(bHost)
        mac.b.prefs.mutate { $0.state = .enabled }

        let remote = RemoteHost(
            id: serverId,
            name: host.name, hostname: host.hostname,
            port: host.port, username: host.username,
            authType: "key",
            createdAt: Date.distantPast,
            updatedAt: Date()
        )
        let bMatchingBatch = HostChangeBatch(
            changedHosts: [remote],
            deletedHostIDs: [],
            credentialBlobsByServerId: [serverId: pushed.blob],
            checkpoint: FakeCheckpoint(id: UUID()),
            tokenExpired: false, mode: .forceFull
        )
        mac.b.fake.fetchSnapshotResult = bMatchingBatch
        mac.b.fake.fetchSnapshotResultRetry = bMatchingBatch

        try await mac.b.store.sync()

        // Mac B got the passphrase in keychain.
        XCTAssertEqual(
            try mac.b.keychain.get(account: "\(bHostId.uuidString).keyPassphrase"),
            "pp",
            "Mac B should have decrypted Mac A's passphrase"
        )

        // Mac B's ManagedKeyStore got the private-key bytes.
        let bRead = try mac.b.managed.read(hostId: bHostId)
        XCTAssertEqual(
            bRead, pkBytes,
            "Mac B's ManagedKeyStore should hold the decrypted private key bytes"
        )

        // Mac B's host credential is now .keyFile pointing at its OWN managed path.
        let bRefreshed = mac.b.session.hosts.first { $0.id == bHostId }!
        if case let .keyFile(keyPath, hasPassphrase) = bRefreshed.credential {
            XCTAssertEqual(
                keyPath, mac.b.managed.path(hostId: bHostId).path,
                "Mac B's keyPath should reference its OWN ManagedKeyStore entry, not Mac A's"
            )
            XCTAssertTrue(hasPassphrase)
        } else {
            XCTFail("Mac B's credential should be .keyFile after pull")
        }
    }

    func test_pushDirtyBitClearedAfterSuccessfulPush() async throws {
        let mac = try await makeTwoMacs()

        mac.a.prefs.mutate { $0.state = .enabled }
        let aHostId = UUID()
        let host = SSHHost(
            id: aHostId,
            name: "gamma", hostname: "c.example", port: 22,
            username: "u", credential: .password,
            createdAt: Date.distantPast, updatedAt: Date.distantPast
        )
        try mac.a.session.addHost(host)
        try mac.a.session.setServerId("rec-A3", for: aHostId)
        try mac.a.session.setHostCredentialMaterial(
            secrets: HostSecrets(password: Data("p1".utf8)),
            credentialSource: .password,
            for: aHostId
        )

        // Sanity: dirty bit is on before sync.
        XCTAssertEqual(
            mac.a.session.hosts.first { $0.id == aHostId }?.credentialMaterialDirty,
            true,
            "dirty bit should be set after setHostCredentialMaterial"
        )

        let aLive = mac.a.session.hosts.first { $0.id == aHostId }!
        let aMatchingBatch = HostChangeBatch(
            changedHosts: [
                RemoteHost(
                    id: "rec-A3", name: aLive.name, hostname: aLive.hostname,
                    port: aLive.port, username: aLive.username,
                    authType: "password",
                    createdAt: aLive.createdAt, updatedAt: aLive.updatedAt
                ),
            ],
            deletedHostIDs: [],
            checkpoint: FakeCheckpoint(id: UUID()),
            tokenExpired: false, mode: .forceFull
        )
        mac.a.fake.fetchSnapshotResult = aMatchingBatch
        mac.a.fake.fetchSnapshotResultRetry = aMatchingBatch
        try await mac.a.store.sync()

        // Dirty bit cleared after push.
        XCTAssertEqual(
            mac.a.session.hosts.first { $0.id == aHostId }?.credentialMaterialDirty,
            false,
            "credentialMaterialDirty must be cleared after a successful push"
        )
    }

    // MARK: - Fixture

    private struct Mac {
        let store: HostSyncStore
        let session: SessionStore
        let prefs: CredentialSyncPreferencesStore
        let fake: FakeIncrementalHostSyncClient
        let managed: ManagedKeyStore
        let keychain: KeychainStore
    }

    private struct TwoMacs {
        let a: Mac
        let b: Mac
    }

    /// Builds two Mac fixtures sharing one master key (via a shared
    /// `KeychainSyncMasterKeyStore.service` string) but with otherwise
    /// independent state: separate `SessionStore`, `ManagedKeyStore`,
    /// `KeychainStore` (for SSH secrets), `CredentialSyncPreferencesStore`,
    /// `SyncPreferences`, and `FakeIncrementalHostSyncClient`.
    private func makeTwoMacs() async throws -> TwoMacs {
        // Generate the shared master key on Mac A's store; Mac B sees it via
        // loadAny() because they share `service`. Mirrors how iCloud Keychain
        // would replicate the key in production.
        let masterA = KeychainSyncMasterKeyStore(
            service: sharedMasterKeyService, synchronizable: false
        )
        let masterB = KeychainSyncMasterKeyStore(
            service: sharedMasterKeyService, synchronizable: false
        )
        _ = try await masterA.generate()
        // Sanity check that B sees the same key.
        let aPair = await masterA.loadAny()
        let bPair = await masterB.loadAny()
        XCTAssertNotNil(aPair)
        XCTAssertNotNil(bPair)
        XCTAssertEqual(
            aPair?.keyID, bPair?.keyID,
            "Both Macs must resolve the same master key (test fixture invariant)"
        )

        let a = makeMac(masterKey: masterA, suffix: "A")
        let b = makeMac(masterKey: masterB, suffix: "B")
        return TwoMacs(a: a, b: b)
    }

    private func makeMac(
        masterKey: KeychainSyncMasterKeyStore,
        suffix: String
    ) -> Mac {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(suffix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )
        let hostsURL = tmp.appendingPathComponent("hosts.json")
        let keychain = KeychainStore(
            service: "e2e-secrets-\(suffix)-\(UUID().uuidString)",
            accessGroup: nil
        )
        let session = SessionStore(
            askpassPath: "/x", knownHostsCaterm: "/A", knownHostsUser: "/B",
            accessGroup: nil, hostsURL: hostsURL, keychain: keychain
        )
        let isolatedDefaults = UserDefaults(
            suiteName: "e2e-syncprefs-\(suffix)-\(UUID().uuidString)"
        )!
        let syncPrefs = SyncPreferences(defaults: isolatedDefaults)
        let prefs = CredentialSyncPreferencesStore(
            defaults: UserDefaults(
                suiteName: "e2e-credprefs-\(suffix)-\(UUID().uuidString)"
            )!
        )
        let managedRoot = tmp.appendingPathComponent(
            "managed-keys", isDirectory: true
        )
        let managed = ManagedKeyStore(rootURL: managedRoot)
        let fake = FakeIncrementalHostSyncClient()
        let store = HostSyncStore(
            client: fake,
            sessionStore: session,
            authSession: FakeAuthSession(isSignedIn: true),
            preferences: syncPrefs,
            credentialSync: prefs,
            masterKeyStore: masterKey,
            managedKeyStore: managed,
            // Use a long debounce so SessionStore mutations don't kick off a
            // racing auto-sync that consumes our staged fetchSnapshotResult
            // before the test's explicit `sync()` runs. Manual sync()
            // bypasses the debounce; auto-sync inherits this interval.
            debounceInterval: 60.0,
            userDefaults: isolatedDefaults
        )
        return Mac(
            store: store, session: session, prefs: prefs,
            fake: fake, managed: managed, keychain: keychain
        )
    }
}
