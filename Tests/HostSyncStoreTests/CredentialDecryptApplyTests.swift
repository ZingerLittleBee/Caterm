import CredentialSyncStore
import CredentialSyncTypes
import CryptoKit
import KeychainStore
import ManagedKeyStore
import XCTest
@testable import HostSyncStore
@testable import ServerSyncClient
@testable import SessionStore
@testable import SSHCommandBuilder

/// Plan C / Task 17 — `decryptAndApply` happy path, master-key-missing
/// hard invariant, and bounded 3-strike retry on AAD/decrypt failure.
@MainActor
final class CredentialDecryptApplyTests: XCTestCase {
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
    private var tmp: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-decrypt-apply-\(UUID().uuidString)")
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
        isolatedDefaults = UserDefaults(suiteName: "caterm-decrypt-apply-\(UUID().uuidString)")!
        syncPrefs = SyncPreferences(defaults: isolatedDefaults)
        prefsStore = CredentialSyncPreferencesStore(
            defaults: UserDefaults(suiteName: "creds-decrypt-\(UUID().uuidString)")!
        )
        masterKeyStore = KeychainSyncMasterKeyStore(
            service: "test-\(UUID().uuidString)",
            synchronizable: false
        )
        managedKeyRoot = tmp.appendingPathComponent("managed-keys", isDirectory: true)
        managedKeyStore = ManagedKeyStore(rootURL: managedKeyRoot)
    }

    override func tearDown() async throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        try await super.tearDown()
    }

    // MARK: - Test 1 — happy path: all 3 ciphertexts round-trip

    func test_payloadDecrypt_writesKeychain_writesManagedKeyStore_advancesLastApplied() async throws {
        prefsStore.mutate { $0.state = .enabled }
        let host = seedLocalHost(serverId: "rec-1")

        // Generate the master key in the same store the SUT will use.
        let resolved = try await masterKeyStore.generate()
        let key = resolved.key
        let keyID = resolved.keyID

        // Build ciphertexts with proper AAD (serverId="rec-1", revision=1).
        let serverId = "rec-1"
        let revision: Int64 = 1
        let pwPlain = Data("p1".utf8)
        let ppPlain = Data("pp1".utf8)
        let pkPlain = Data("pkbytes".utf8)
        let pwCt = try EnvelopeCrypto.seal(
            pwPlain, key: key,
            aad: EnvelopeCrypto.aad(serverId: serverId, fieldKind: .password, revision: revision)
        )
        let ppCt = try EnvelopeCrypto.seal(
            ppPlain, key: key,
            aad: EnvelopeCrypto.aad(serverId: serverId, fieldKind: .passphrase, revision: revision)
        )
        let pkCt = try EnvelopeCrypto.seal(
            pkPlain, key: key,
            aad: EnvelopeCrypto.aad(serverId: serverId, fieldKind: .privateKey, revision: revision)
        )

        let remote = makeNewerRemote(serverId: serverId, host: host)
        let blob = CredentialBlob(
            state: .payload, revision: revision, keyID: keyID,
            cryptoVersion: Int64(EnvelopeCrypto.schemaVersion),
            passwordCiphertext: pwCt,
            passphraseCiphertext: ppCt,
            privateKeyCiphertext: pkCt
        )
        seedBatch(remote: remote, blob: blob)

        let sut = makeStore()
        try await sut.sync()

        // Keychain — password and passphrase round-tripped.
        XCTAssertEqual(
            try keychain.get(account: "\(host.id.uuidString).password"), "p1",
            "password ciphertext must be decrypted and persisted to keychain"
        )
        XCTAssertEqual(
            try keychain.get(account: "\(host.id.uuidString).keyPassphrase"), "pp1",
            "passphrase ciphertext must be decrypted and persisted to keychain"
        )

        // ManagedKeyStore — private-key bytes written.
        let pkOnDisk = try managedKeyStore.read(hostId: host.id)
        XCTAssertEqual(pkOnDisk, pkPlain,
                       "private-key ciphertext must be decrypted and written via ManagedKeyStore")

        // SessionStore — host.credential transitioned to .keyFile with passphrase.
        let updatedHost = sessionStore.hosts.first { $0.id == host.id }
        XCTAssertNotNil(updatedHost)
        if case let .keyFile(keyPath, hasPassphrase) = updatedHost?.credential {
            XCTAssertTrue(hasPassphrase, "passphrase present → hasPassphrase must be true")
            XCTAssertEqual(
                keyPath, managedKeyStore.path(hostId: host.id).path,
                "host.credential keyPath must match managedKeyStore-issued path"
            )
        } else {
            XCTFail("expected .keyFile credential, got \(String(describing: updatedHost?.credential))")
        }

        // lastAppliedRevision advanced.
        XCTAssertEqual(
            prefsStore.prefs.lastAppliedRevision[host.id], revision,
            "lastAppliedRevision must bump on success"
        )
        // No corrupt entry recorded on the happy path.
        XCTAssertTrue(prefsStore.prefs.corruptCredentials.isEmpty,
                      "happy path must not mark anything corrupt")
    }

    // MARK: - Test 2 — master key absent: state→waitingForKey, no advance, throws

    func test_masterKeyAbsent_transitionsToWaitingForKey_doesNotAdvance_throws() async throws {
        prefsStore.mutate { $0.state = .enabled }
        let host = seedLocalHost(serverId: "rec-1")

        // Master-key store is empty (no generate() call). load(keyID:) → nil.
        let absentKeyID = "some-key-id-not-in-store"
        let blob = CredentialBlob(
            state: .payload, revision: 1, keyID: absentKeyID,
            passwordCiphertext: Data([0x01])
        )
        let remote = makeNewerRemote(serverId: "rec-1", host: host)
        seedBatch(remote: remote, blob: blob)

        let sut = makeStore()
        do {
            try await sut.sync()
            XCTFail("sync must throw when master key is missing (hard invariant)")
        } catch {
            // Expected — the cycle aborts.
        }

        XCTAssertEqual(
            prefsStore.prefs.state, .waitingForKey(observedKeyID: absentKeyID),
            "missing master key must transition state to .waitingForKey"
        )
        XCTAssertNil(
            prefsStore.prefs.lastAppliedRevision[host.id],
            "missing master key must NOT advance lastAppliedRevision"
        )
        XCTAssertNil(
            try? keychain.get(account: "\(host.id.uuidString).password"),
            "missing master key must not write to keychain"
        )
    }

    // MARK: - Test 3 — AAD mismatch: 3 strikes → corruptCredentials + advance

    func test_aadMismatch_throws_dirtyAdvancesAfter3Attempts() async throws {
        prefsStore.mutate { $0.state = .enabled }
        let host = seedLocalHost(serverId: "rec-1")

        // Generate a real key so the master-key resolution succeeds; the
        // failure has to come from AAD mismatch, not key-missing.
        let resolved = try await masterKeyStore.generate()
        let key = resolved.key
        let keyID = resolved.keyID

        // Encrypt with revision=99 but build the blob with revision=1 — AAD
        // won't match on open, so EnvelopeCrypto.open throws decryptionFailed.
        let serverId = "rec-1"
        let pwCt = try EnvelopeCrypto.seal(
            Data("p1".utf8), key: key,
            aad: EnvelopeCrypto.aad(serverId: serverId, fieldKind: .password, revision: 99)
        )
        let blob = CredentialBlob(
            state: .payload, revision: 1, keyID: keyID,
            cryptoVersion: Int64(EnvelopeCrypto.schemaVersion),
            passwordCiphertext: pwCt
        )
        let sut = makeStore()

        // Attempts 1, 2, 3: each cycle the local's `updatedAt` was set to
        // the remote's by `applyRemoteMetadata`, so the next remote needs
        // a strictly newer `updatedAt` for the reconciler to emit
        // `.updateLocal` again. Re-seed both fetch slots to keep the same
        // bad blob in flight.
        for attempt in 1...3 {
            let remote = makeNewerRemote(serverId: serverId, host: host)
            seedBatch(remote: remote, blob: blob)
            do {
                try await sut.sync()
                XCTFail("attempt \(attempt) must throw on AAD mismatch (hard invariant)")
            } catch {
                // Expected.
            }
            if attempt < 3 {
                XCTAssertTrue(
                    prefsStore.prefs.corruptCredentials.isEmpty,
                    "after attempt \(attempt) corruptCredentials should still be empty"
                )
                XCTAssertNil(
                    prefsStore.prefs.lastAppliedRevision[host.id],
                    "after attempt \(attempt) lastAppliedRevision must not advance"
                )
            }
            // Tiny sleep so each call to `Date()` in makeNewerRemote produces
            // a strictly later timestamp than the local's just-applied one.
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let expectedKey = CorruptCredentialKey(hostId: host.id, revision: 1)
        XCTAssertTrue(
            prefsStore.prefs.corruptCredentials.contains(expectedKey),
            "after 3 strikes the bad blob must be marked corrupt"
        )
        XCTAssertEqual(
            prefsStore.prefs.lastAppliedRevision[host.id], 1,
            "after 3 strikes lastAppliedRevision must advance past the bad revision"
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
            managedKeyStore: managedKeyStore,
            debounceInterval: 0.05,
            userDefaults: isolatedDefaults
        )
    }

    @discardableResult
    private func seedLocalHost(serverId: String) -> SSHHost {
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
        try? sessionStore.addHost(host)
        return host
    }

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

    private func seedBatch(remote: RemoteHost, blob: CredentialBlob) {
        fakeClient.fetchSnapshotResult = HostChangeBatch(
            changedHosts: [remote],
            deletedHostIDs: [],
            credentialBlobsByServerId: [remote.id: blob],
            checkpoint: nil,
            tokenExpired: false,
            mode: .forceFull
        )
        // Re-arm the same batch on retry — tests 2 & 3 may hit the
        // tokenExpired retry path or just need the same blob each cycle.
        fakeClient.fetchSnapshotResultRetry = fakeClient.fetchSnapshotResult
    }
}
