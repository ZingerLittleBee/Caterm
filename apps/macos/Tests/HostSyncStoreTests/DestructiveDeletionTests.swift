import CredentialSync
import CredentialSyncStore
import CredentialSyncTypes
import KeychainStore
import ManagedKeyStore
import XCTest
@testable import HostSyncStore
@testable import ServerSyncClient
@testable import SessionStore
@testable import SSHCommandBuilder

/// Plan C / Task 20 — destructive deletion durable resumable flow.
///
/// `DestructiveDeletionFlow.confirm` atomically clears every host's
/// `credentialMaterialDirty` bit and stages a persisted
/// `DeletionProgress(pendingLocalHostIds: …)`. The matching driver in
/// `HostSyncStore.runDestructiveSubPipeline` pushes a `.tombstone` blob per
/// host and shrinks the persisted list as each push succeeds. A push that
/// throws aborts the loop without dropping the failed host from the list, so
/// the next cycle resumes naturally.
@MainActor
final class DestructiveDeletionTests: XCTestCase {
    private var sessionStore: SessionStore!
    private var fakeClient: FakeIncrementalHostSyncClient!
    private var prefsStore: CredentialSyncPreferencesStore!
    private var syncPrefs: SyncPreferences!
    private var isolatedDefaults: UserDefaults!
    private var hostsURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-destructive-\(UUID().uuidString)")
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
        fakeClient.fetchSnapshotResult = HostChangeBatch(
            changedHosts: [], deletedHostIDs: [],
            checkpoint: nil, tokenExpired: false, mode: .forceFull
        )
        isolatedDefaults = UserDefaults(suiteName: "caterm-destructive-\(UUID().uuidString)")!
        syncPrefs = SyncPreferences(defaults: isolatedDefaults)
        prefsStore = CredentialSyncPreferencesStore(
            defaults: UserDefaults(suiteName: "creds-destructive-\(UUID().uuidString)")!
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent())
        try await super.tearDown()
    }

    // MARK: - 1. confirm() atomicity

    func test_confirmAtomicallyClearsAllDirtyBits_andSetsInProgress() throws {
        let hostA = makeHost(name: "A", dirty: true)
        try sessionStore.setServerId("rec-a", for: hostA.id)
        let hostB = makeHost(name: "B", dirty: true)
        try sessionStore.setServerId("rec-b", for: hostB.id)
        // Locally-only host (no serverId) — must NOT appear in pending list.
        let localOnly = makeHost(name: "C", dirty: true)

        DestructiveDeletionFlow.confirm(
            sessionStore: sessionStore,
            credentialSync: prefsStore
        )

        for host in sessionStore.hosts {
            XCTAssertFalse(host.credentialMaterialDirty,
                           "confirm() must clear every host's dirty bit")
        }
        let progress = prefsStore.prefs.deleteCredentialsFromCloudInProgress
        XCTAssertNotNil(progress, "confirm() must record DeletionProgress")
        let pending = progress?.pendingLocalHostIds ?? []
        XCTAssertTrue(pending.contains(hostA.id))
        XCTAssertTrue(pending.contains(hostB.id))
        XCTAssertFalse(pending.contains(localOnly.id),
                       "hosts without serverId have nothing to tombstone")
        XCTAssertEqual(pending.count, 2)
    }

    // MARK: - 2. Sub-pipeline tombstones each host atomically

    func test_subPipelineTombstonesEachHost_atomicallyShrinksList() async throws {
        let hostA = makeHost(name: "A")
        try sessionStore.setServerId("rec-a", for: hostA.id)
        let hostB = makeHost(name: "B")
        try sessionStore.setServerId("rec-b", for: hostB.id)
        prefsStore.mutate {
            $0.deleteCredentialsFromCloudInProgress = DeletionProgress(
                pendingLocalHostIds: [hostA.id, hostB.id]
            )
        }

        let sut = makeStore()
        try await sut.sync()

        XCTAssertEqual(fakeClient.pushCredentialCalls.count, 2,
                       "each pending host must produce one tombstone push")
        for call in fakeClient.pushCredentialCalls {
            XCTAssertEqual(call.blob.state, .tombstone)
            XCTAssertEqual(call.blob.revision, 1,
                           "first tombstone for each host uses revision = 1")
            XCTAssertNil(call.blob.keyID, "tombstone carries no keyID")
        }
        XCTAssertNil(prefsStore.prefs.deleteCredentialsFromCloudInProgress,
                     "outer flag must clear after both hosts tombstoned")
        XCTAssertEqual(prefsStore.prefs.lastAppliedRevision[hostA.id], 1)
        XCTAssertEqual(prefsStore.prefs.lastAppliedRevision[hostB.id], 1)
        XCTAssertTrue(fakeClient.fetchModes.isEmpty,
                      "destructive sub-pipeline must skip the normal fetch")
    }

    // MARK: - 3. Simulated crash between hosts

    func test_simulatedCrashBetweenHosts_resumesFromPersistedList() async throws {
        let hostA = makeHost(name: "A")
        try sessionStore.setServerId("rec-a", for: hostA.id)
        let hostB = makeHost(name: "B")
        try sessionStore.setServerId("rec-b", for: hostB.id)
        prefsStore.mutate {
            $0.deleteCredentialsFromCloudInProgress = DeletionProgress(
                pendingLocalHostIds: [hostA.id, hostB.id]
            )
        }

        // First cycle: second push throws. Sub-pipeline aborts with hostA
        // already shrunk from the list and hostB still pending.
        fakeClient.pushCredentialError = NSError(
            domain: "test", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "simulated crash on B"]
        )
        fakeClient.pushCredentialFailAtIndex = 1

        let sut = makeStore()
        do {
            try await sut.sync()
        } catch {
            // Sub-pipeline swallows the error via early `return`; outer cycle
            // completes normally. No throw is expected — but tolerate either.
        }

        XCTAssertEqual(fakeClient.pushCredentialCalls.count, 1,
                       "only hostA's tombstone was recorded before the crash")
        let mid = prefsStore.prefs.deleteCredentialsFromCloudInProgress
        XCTAssertNotNil(mid, "outer flag must remain while hostB is pending")
        XCTAssertEqual(mid?.pendingLocalHostIds, [hostB.id],
                       "hostA was atomically removed before hostB threw")
        XCTAssertEqual(prefsStore.prefs.lastAppliedRevision[hostA.id], 1)
        XCTAssertNil(prefsStore.prefs.lastAppliedRevision[hostB.id])

        // Second cycle: clear the error, run sync again. hostB tombstones.
        fakeClient.pushCredentialError = nil
        fakeClient.pushCredentialFailAtIndex = nil
        try await sut.sync()

        XCTAssertEqual(fakeClient.pushCredentialCalls.count, 2,
                       "second cycle pushes the remaining host")
        let lastCall = fakeClient.pushCredentialCalls[1]
        XCTAssertEqual(lastCall.serverId, "rec-b")
        XCTAssertEqual(lastCall.blob.state, .tombstone)
        XCTAssertNil(prefsStore.prefs.deleteCredentialsFromCloudInProgress,
                     "flag clears once the resumed list empties")
        XCTAssertEqual(prefsStore.prefs.lastAppliedRevision[hostB.id], 1)
    }

    // MARK: - 4. In-progress suppresses dirty-scan

    func test_inProgress_suppressesDirtyScan_pushesNoCredentials() async throws {
        // Dirty host with serverId and prefs.state=.enabled — the dirty-scan
        // would normally queue `.updateRemoteCredentials` for it. Setting
        // deleteCredentialsFromCloudInProgress short-circuits performSync
        // before the scan executes, so no payload push is emitted.
        prefsStore.mutate { $0.state = .enabled }
        let dirty = SSHHost(
            name: "dirty", hostname: "h", port: 22, username: "u",
            credential: .password, credentialMaterialDirty: true
        )
        try sessionStore.addHost(dirty)
        try sessionStore.setServerId("rec-dirty", for: dirty.id)

        let other = makeHost(name: "other")
        try sessionStore.setServerId("rec-other", for: other.id)
        prefsStore.mutate {
            $0.deleteCredentialsFromCloudInProgress = DeletionProgress(
                pendingLocalHostIds: [other.id]
            )
        }

        let sut = makeStore()
        try await sut.sync()

        XCTAssertFalse(
            sut.lastAppliedOpsForTesting.contains(where: { op in
                if case .updateRemoteCredentials = op { return true }
                return false
            }),
            "destructive in-progress must skip the dirty-scan op queue"
        )
        XCTAssertEqual(fakeClient.pushCredentialCalls.count, 1,
                       "only the destructive tombstone for the pending host")
        XCTAssertEqual(fakeClient.pushCredentialCalls[0].blob.state, .tombstone)
        XCTAssertEqual(fakeClient.pushCredentialCalls[0].serverId, "rec-other")
    }

    // MARK: - confirm() invokes triggerSync callback

    func test_confirmInvokesTriggerSyncCallback_evenWhenNoHosts() {
        var triggered = 0
        DestructiveDeletionFlow.confirm(
            sessionStore: sessionStore,
            credentialSync: prefsStore,
            triggerSync: { triggered += 1 }
        )
        XCTAssertEqual(triggered, 1,
                       "confirm must kick the sync pipeline immediately so the user "
                       + "doesn't have to click Sync Now to push tombstones")
    }

    // MARK: - cloudCredentialsCleared flag transitions

    func test_subPipelineComplete_setsCloudCredentialsClearedTrue() async throws {
        let host = makeHost(name: "tombstone-target")
        try sessionStore.setServerId("rec-x", for: host.id)
        prefsStore.mutate {
            $0.deleteCredentialsFromCloudInProgress = DeletionProgress(
                pendingLocalHostIds: [host.id]
            )
            // Pretend nothing was previously cleared, but the host had a
            // payload before destructive started — the tombstone push must
            // remove it from the payload-tracking set.
            $0.cloudCredentialsCleared = false
            $0.hostsWithCloudPayload = [host.id]
        }

        let sut = makeStore()
        try await sut.sync()

        XCTAssertNil(prefsStore.prefs.deleteCredentialsFromCloudInProgress,
                     "outer flag must clear once the list is empty")
        XCTAssertTrue(prefsStore.prefs.cloudCredentialsCleared,
                      "completing the destructive sub-pipeline must mark cloud cleared "
                      + "so the UI hides the delete button and stops counting payloads")
        XCTAssertFalse(prefsStore.prefs.hostsWithCloudPayload.contains(host.id),
                       "tombstone push must drop the host from the payload-tracking set")
    }

    func test_subPipelineMidFlight_doesNotPrematurelySetCloudCleared() async throws {
        // Two hosts pending, second tombstone push fails. cloudCredentialsCleared
        // must NOT flip true while the list still has remaining hosts.
        let hostA = makeHost(name: "A")
        try sessionStore.setServerId("rec-a", for: hostA.id)
        let hostB = makeHost(name: "B")
        try sessionStore.setServerId("rec-b", for: hostB.id)
        prefsStore.mutate {
            $0.deleteCredentialsFromCloudInProgress = DeletionProgress(
                pendingLocalHostIds: [hostA.id, hostB.id]
            )
            $0.cloudCredentialsCleared = false
        }
        fakeClient.pushCredentialError = NSError(
            domain: "test", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "simulated B failure"]
        )
        fakeClient.pushCredentialFailAtIndex = 1

        let sut = makeStore()
        try? await sut.sync()

        XCTAssertNotNil(prefsStore.prefs.deleteCredentialsFromCloudInProgress,
                        "outer flag must remain while hostB is pending")
        XCTAssertFalse(prefsStore.prefs.cloudCredentialsCleared,
                       "cloudCredentialsCleared must NOT flip true mid-flight")
    }

    // MARK: - 5. Empty pending list clears outer flag

    func test_emptyList_clearsOuterFlag_resumesNormalPipeline() async throws {
        prefsStore.mutate {
            $0.deleteCredentialsFromCloudInProgress = DeletionProgress(
                pendingLocalHostIds: []
            )
        }

        let sut = makeStore()
        try await sut.sync()

        XCTAssertNil(prefsStore.prefs.deleteCredentialsFromCloudInProgress,
                     "empty pending list must clear the outer flag")
        XCTAssertTrue(fakeClient.fetchModes.isEmpty,
                      "normal fetch is still skipped in the cleanup cycle")

        // Subsequent cycle resumes the normal pipeline.
        try await sut.sync()
        XCTAssertGreaterThanOrEqual(fakeClient.fetchModes.count, 1,
                                    "normal sync must run on the next cycle")
    }

    // MARK: - 6. Edit during deletion clears dirty + does not re-populate

    func test_editDuringDeletion_clearsDirtyAfterSet_doesNotRepopulate() async throws {
        let host = makeHost(name: "editing")
        try sessionStore.setServerId("rec-edit", for: host.id)
        prefsStore.mutate {
            $0.deleteCredentialsFromCloudInProgress = DeletionProgress(
                pendingLocalHostIds: [UUID()]
            )
        }

        let sut = makeStore()
        _ = sut
        let fetchCountBefore = fakeClient.fetchModes.count

        // Mutate via the public API so the notification path mirrors real
        // user edits: setHostCredentialMaterial sets dirty=true, persists,
        // then posts catermHostCredentialMaterialChanged.
        try sessionStore.setHostCredentialMaterial(
            secrets: HostSecrets(password: Data("p".utf8)),
            credentialSource: .password,
            for: host.id
        )

        // Wait long enough that any auto-sync would have been scheduled.
        // 200ms is well above the default 50ms debounce we use in tests.
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let refreshed = sessionStore.hosts.first { $0.id == host.id }
        XCTAssertEqual(refreshed?.credentialMaterialDirty, false,
                       "observer must clear dirty bit during destructive deletion")
        XCTAssertEqual(fakeClient.fetchModes.count, fetchCountBefore,
                       "no sync cycle must be triggered by the notification")
        XCTAssertTrue(fakeClient.pushCredentialCalls.isEmpty,
                      "no credential push must be emitted")
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
    private func makeHost(name: String, dirty: Bool = false) -> SSHHost {
        let host = SSHHost(
            name: name, hostname: "h", port: 22, username: "u",
            credential: .password, credentialMaterialDirty: dirty
        )
        try? sessionStore.addHost(host)
        return host
    }
}
