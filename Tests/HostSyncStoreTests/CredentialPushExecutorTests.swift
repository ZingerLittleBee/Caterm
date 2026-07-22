import CredentialSyncStore
import CredentialSyncTypes
import KeychainStore
import ManagedKeyStore
import XCTest
@testable import HostSyncStore
@testable import ServerSyncClient
@testable import SessionStore
@testable import SSHCommandBuilder

/// Plan C / Task 14 — `.updateRemoteCredentials` executor tests.
///
/// Each test stages a real (but isolated) keychain master key via
/// `KeychainSyncMasterKeyStore(service: "test-...", synchronizable: false)`.
/// `synchronizable: false` is required because Swift test binaries lack the
/// `keychain-access-groups` entitlement that synchronizable items demand
/// (errSecMissingEntitlement -34018, recorded in Plan A's verification log).
@MainActor
final class CredentialPushExecutorTests: XCTestCase {
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
            .appendingPathComponent("caterm-credpush-\(UUID().uuidString)")
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
        // Empty snapshot — reconciler emits no metadata ops, so the only
        // ops produced come from the Plan-C dirty scan.
        fakeClient.fetchSnapshotResult = HostChangeBatch(
            changedHosts: [], deletedHostIDs: [],
            checkpoint: nil, tokenExpired: false, mode: .forceFull
        )
        isolatedDefaults = UserDefaults(suiteName: "caterm-credpush-\(UUID().uuidString)")!
        syncPrefs = SyncPreferences(defaults: isolatedDefaults)
        prefsStore = CredentialSyncPreferencesStore(
            defaults: UserDefaults(suiteName: "creds-\(UUID().uuidString)")!
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

    // MARK: - Tests

    func test_executor_serverIdNil_isNoOp_keepsDirty() async throws {
        // Spec: "createRemote in this cycle hasn't run / failed". We model
        // that here by failing createHost — the cycle aborts before
        // .updateRemoteCredentials, so the executor never even runs. The
        // important assertions hold either way: no push call, dirty stays.
        prefsStore.mutate { $0.state = .enabled }
        let host = makeDirtyHost()
        try await stageMasterKey()
        fakeClient.createHostError = NSError(
            domain: "test", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "simulated createRemote failure"]
        )

        let sut = makeStore()
        do {
            try await sut.sync()
        } catch {
            // Expected — createRemote failure aborts the cycle.
        }

        XCTAssertTrue(
            fakeClient.pushCredentialCalls.isEmpty,
            "host without serverId must not produce a credential push"
        )
        let refreshed = sessionStore.hosts.first { $0.id == host.id }
        XCTAssertEqual(
            refreshed?.credentialMaterialDirty, true,
            "dirty bit must remain set when no push has succeeded"
        )
    }

    func test_executor_serverIdPresent_pushesAndClearsDirty() async throws {
        prefsStore.mutate { $0.state = .enabled }
        let host = makeDirtyHost()
        try sessionStore.setServerId("rec-1", for: host.id)
        try sessionStore.setHostSecret("p1", hostId: host.id, kind: .password)
        try await stageMasterKey()
        // Snapshot must contain the host as-is so the reconciler emits no
        // metadata op (updatedAt equals → no-op). Without this, the empty
        // snapshot would make the reconciler emit `.deleteLocal`, removing
        // the host before the executor runs.
        seedSnapshotMatchingLocal(serverId: "rec-1", host: host)

        let sut = makeStore()
        try await sut.sync()

        XCTAssertEqual(fakeClient.pushCredentialCalls.count, 1)
        let call = fakeClient.pushCredentialCalls[0]
        XCTAssertEqual(call.serverId, "rec-1")
        XCTAssertEqual(call.blob.state, .payload)
        XCTAssertEqual(call.blob.revision, 1, "first push must use revision = 1")
        XCTAssertNotNil(call.blob.passwordCiphertext, "password secret must be sealed")
        let refreshed = sessionStore.hosts.first { $0.id == host.id }
        XCTAssertEqual(
            refreshed?.credentialMaterialDirty, false,
            "dirty bit must be cleared after a successful push"
        )
        XCTAssertEqual(prefsStore.prefs.lastAppliedRevision[host.id], 1)
    }

    /// After a destructive flow leaves `cloudCredentialsCleared = true`, the
    /// next successful payload push must flip it back to false so the UI
    /// resumes counting synced hosts and re-enables the delete button.
    /// Also inserts the host into `hostsWithCloudPayload` so the count is
    /// computed off real payload presence rather than `revision > 0`
    /// (tombstones bump the revision too).
    func test_payloadPush_clearsCloudCredentialsClearedFlag_andTracksHost() async throws {
        prefsStore.mutate {
            $0.state = .enabled
            $0.cloudCredentialsCleared = true  // simulate post-destructive state
            $0.hostsWithCloudPayload = []
        }
        let host = makeDirtyHost()
        try sessionStore.setServerId("rec-1", for: host.id)
        try sessionStore.setHostSecret("p1", hostId: host.id, kind: .password)
        try await stageMasterKey()
        seedSnapshotMatchingLocal(serverId: "rec-1", host: host)

        let sut = makeStore()
        try await sut.sync()

        XCTAssertEqual(fakeClient.pushCredentialCalls.count, 1)
        XCTAssertEqual(fakeClient.pushCredentialCalls[0].blob.state, .payload)
        XCTAssertFalse(prefsStore.prefs.cloudCredentialsCleared,
                       "a successful payload push must invalidate the cloud-cleared marker")
        XCTAssertTrue(prefsStore.prefs.hostsWithCloudPayload.contains(host.id),
                      "successful payload push must add the host to the payload-tracking set")
    }

    func test_executor_pushFailure_keepsDirty_propagates_abortsCheckpoint() async throws {
        prefsStore.mutate { $0.state = .enabled }
        let host = makeDirtyHost()
        try sessionStore.setServerId("rec-1", for: host.id)
        try sessionStore.setHostSecret("p1", hostId: host.id, kind: .password)
        try await stageMasterKey()

        // Snapshot includes the host so reconciler emits no metadata op,
        // and a checkpoint so we can prove commit is NOT called when the
        // executor throws.
        let checkpoint = FakeCheckpoint(id: UUID())
        let remote = makeRemoteHostMatchingLocal(serverId: "rec-1", host: host)
        fakeClient.fetchSnapshotResult = HostChangeBatch(
            changedHosts: [remote], deletedHostIDs: [],
            checkpoint: checkpoint, tokenExpired: false, mode: .forceFull
        )
        fakeClient.pushCredentialError = NSError(
            domain: "test", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "simulated push failure"]
        )

        let sut = makeStore()
        var didThrow = false
        do {
            try await sut.sync()
        } catch {
            didThrow = true
        }
        XCTAssertTrue(didThrow, "push failure must propagate out of sync()")

        let refreshed = sessionStore.hosts.first { $0.id == host.id }
        XCTAssertEqual(
            refreshed?.credentialMaterialDirty, true,
            "dirty bit must remain set after a failed push"
        )
        XCTAssertTrue(
            fakeClient.commitCalls.isEmpty,
            "checkpoint must not be committed when an op throws"
        )
        XCTAssertNil(
            prefsStore.prefs.lastAppliedRevision[host.id],
            "lastAppliedRevision must not advance on push failure"
        )
    }

	func test_missingRemoteDuringIncrementalCredentialPushRetriesFullSnapshotWithoutRepeatingSuccessfulPushes() async throws {
		prefsStore.mutate { $0.state = .enabled }
		let survivingHost = makeDirtyHost(name: "surviving")
		let deletedHost = makeDirtyHost(name: "deleted")
		try sessionStore.setServerId("rec-surviving", for: survivingHost.id)
		try sessionStore.setServerId("rec-deleted", for: deletedHost.id)
		try sessionStore.setHostSecret(
			"p1", hostId: survivingHost.id, kind: .password
		)
		try sessionStore.setHostSecret(
			"p2", hostId: deletedHost.id, kind: .password
		)
		try await stageMasterKey()
		fakeClient.preferredModeOverride = .incremental
		let incrementalCheckpoint = FakeCheckpoint(id: UUID())
		let fullCheckpoint = FakeCheckpoint(id: UUID())
		let survivingRemote = makeRemoteHostMatchingLocal(
			serverId: "rec-surviving", host: survivingHost
		)
		let deletedRemote = makeRemoteHostMatchingLocal(
			serverId: "rec-deleted", host: deletedHost
		)
		fakeClient.fetchSnapshotResult = HostChangeBatch(
			changedHosts: [survivingRemote, deletedRemote],
			deletedHostIDs: [],
			checkpoint: incrementalCheckpoint,
			tokenExpired: false,
			mode: .incremental
		)
		fakeClient.fetchSnapshotResultRetry = HostChangeBatch(
			changedHosts: [survivingRemote],
			deletedHostIDs: [],
			checkpoint: fullCheckpoint,
			tokenExpired: false,
			mode: .forceFull
		)
		fakeClient.pushCredentialErrorsByServerID["rec-deleted"] =
			ServerSyncError.remoteHostNotFound(serverID: "rec-deleted")

		let sut = makeStore()
		try await sut.sync()

		XCTAssertEqual(fakeClient.fetchModes, [.incremental, .forceFull])
		XCTAssertEqual(fakeClient.commitCalls.map(\.id), [fullCheckpoint.id])
		XCTAssertEqual(
			fakeClient.pushCredentialAttemptServerIDs,
			["rec-surviving", "rec-deleted"]
		)
		XCTAssertTrue(sessionStore.hosts.contains(where: { $0.id == survivingHost.id }))
		XCTAssertFalse(sessionStore.hosts.contains(where: { $0.id == deletedHost.id }))
		XCTAssertNil(sut.lastSyncErrorKind)
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

    @discardableResult
    private func makeDirtyHost(name: String = "dirty") -> SSHHost {
        let host = SSHHost(
            name: name,
            hostname: "h",
            port: 22,
            username: "u",
            credential: .password,
            credentialMaterialDirty: true
        )
        try? sessionStore.addHost(host)
        return host
    }

    private func stageMasterKey() async throws {
        let (id, _) = try await masterKeyStore.generate()
        generatedKeyID = id
    }

    /// Build a `RemoteHost` that mirrors a local host under `serverId`,
    /// preserving `updatedAt` so the reconciler emits no metadata op.
    private func makeRemoteHostMatchingLocal(serverId: String, host: SSHHost) -> RemoteHost {
        // We need the live updatedAt — `setServerId` bumped it.
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
