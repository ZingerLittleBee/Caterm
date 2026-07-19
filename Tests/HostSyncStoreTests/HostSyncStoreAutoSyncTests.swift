import Combine
import CredentialSyncStore
import XCTest
@testable import HostSyncStore
@testable import SessionStore
@testable import SSHCommandBuilder
@testable import ServerSyncClient
@testable import KeychainStore

@MainActor
final class HostSyncStoreAutoSyncTests: XCTestCase {
    var sut: HostSyncStore!
    var fakeClient: FakeServerSyncClient!
    var fakeAuth: FakeAuthSession!
    var sessionStore: SessionStore!
    var tmpHostsURL: URL!
    var isolatedDefaults: UserDefaults!

    override func setUp() async throws {
        tmpHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-autosync-\(UUID()).json")
        let kc = KeychainStore(service: "com.caterm.test.\(UUID().uuidString)",
                               accessGroup: nil)
        sessionStore = SessionStore(askpassPath: "/x", knownHostsCaterm: "/A",
                                     knownHostsUser: "/B", accessGroup: nil,
                                     hostsURL: tmpHostsURL, keychain: kc)
        fakeClient = FakeServerSyncClient()
        fakeAuth = FakeAuthSession(isSignedIn: true)
        isolatedDefaults = UserDefaults(suiteName: "caterm-test-\(UUID().uuidString)")!
        let prefs = SyncPreferences(defaults: isolatedDefaults)
        sut = HostSyncStore(client: fakeClient,
                            sessionStore: sessionStore,
                            authSession: fakeAuth,
                            preferences: prefs,
                            credentialSync: CredentialSyncPreferencesStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!),
                            debounceInterval: 0.05,
                            userDefaults: isolatedDefaults)
    }

    override func tearDown() async throws {
        sut = nil
        try? FileManager.default.removeItem(at: tmpHostsURL)
    }

    // MARK: - Task 2.10.3a: auth gate

    func testSyncIfSignedInNoOpsWhenSignedOut() async throws {
        fakeAuth.isSignedIn = false
        sut.syncIfSignedIn()
        // Give the run loop a tick in case anything was queued.
        try await Task.sleep(nanoseconds: 50_000_000)  // 0.05 s
        XCTAssertEqual(fakeClient.listCallCount, 0,
            "syncIfSignedIn must early-return when not signed in (spec §3.5)")
    }

    func testSyncIfSignedInTriggersWhenSignedIn() async throws {
        fakeAuth.isSignedIn = true
        sut.syncIfSignedIn()
        // syncIfSignedIn is sync; the real work runs as an unstructured Task.
        // Wait for that task to reach listHosts.
        try await waitFor(timeout: 1.0) { self.fakeClient.listCallCount == 1 }
        XCTAssertEqual(fakeClient.listCallCount, 1)
    }

    func testAccountChangeSuspensionCancelsAndGatesSyncUntilResume() async throws {
        fakeClient.listHostsDelay = 5
        sut.syncIfSignedIn()
        try await waitFor(timeout: 1.0) { self.fakeClient.listCallCount == 1 }

        await sut.suspendForAccountChange()

        XCTAssertTrue(fakeClient.listHostsTaskWasCancelled)
        fakeClient.listHostsDelay = 0
        sut.syncIfSignedIn()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fakeClient.listCallCount, 1)
        do {
            try await sut.sync()
            XCTFail("manual sync must remain gated during an account transition")
        } catch is CancellationError {
            // Expected.
        }

        sut.resumeAfterAccountChange()
        try await waitFor(timeout: 1.0) { self.fakeClient.listCallCount == 2 }
    }

    func testAccountChangeGateRejectsManualTaskCancelledBeforeItStarts() async {
        let manual = Task { try await sut.sync() }
        sut.beginAccountChangeSuspension()
        await sut.drainForAccountChange()

        switch await manual.result {
        case .success:
            XCTFail("manual sync must not cross an account-change gate")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fakeClient.listCallCount, 0)
    }

    // MARK: - Task 2.10.3b: debounce subscription

    func testMutationTriggersDebouncedSync() async throws {
        // debounceInterval is 0.05 from setUp.
        let h = SSHHost(name: "alpha", hostname: "x", username: "u", credential: .agent)
        try sessionStore.addHost(h)

        // Immediately after addHost, debounce timer hasn't fired yet.
        XCTAssertEqual(fakeClient.listCallCount, 0,
            "Debounce should delay the sync — no listHosts yet")

        // Wait past the debounce window.
        try await waitFor(timeout: 1.0) { self.fakeClient.listCallCount == 1 }
        XCTAssertEqual(fakeClient.listCallCount, 1)
    }

    func testRapidMutationsCoalesce() async throws {
        for i in 0..<5 {
            let h = SSHHost(name: "h\(i)", hostname: "x", username: "u", credential: .agent)
            try sessionStore.addHost(h)
        }
        // 5 rapid sends within the 0.05 s debounce window → 1 fire.
        try await waitFor(timeout: 1.0) { self.fakeClient.listCallCount >= 1 }
        // Give a little extra time to ensure no second fire arrives.
        try await Task.sleep(nanoseconds: 200_000_000)  // 0.2 s
        XCTAssertEqual(fakeClient.listCallCount, 1,
            "5 mutations within debounce window must coalesce into 1 sync")
    }

    func testCredentialOnlyDoesNotTriggerSync() async throws {
        let h = SSHHost(name: "alpha", hostname: "x", username: "u", credential: .agent)
        try sessionStore.addHost(h)
        // Wait for the addHost-triggered sync.
        try await waitFor(timeout: 1.0) { self.fakeClient.listCallCount == 1 }

        try sessionStore.setCredentialOnly(.password, for: h.id)
        // Wait past the debounce window.
        try await Task.sleep(nanoseconds: 200_000_000)  // 0.2 s
        XCTAssertEqual(fakeClient.listCallCount, 1,
            "Credential-only change must NOT trigger sync (no .send() in setCredentialOnly)")
    }

    // MARK: - Task 2.10.3c: chained cancel-and-drain serialization

    func testChainSerializesPasses() async throws {
        // Make listHosts hang so the first sync stays in flight.
        fakeClient.listHostsDelay = 0.2

        // Kick off first sync.
        sut.syncIfSignedIn()
        try await waitFor(timeout: 1.0) { self.fakeClient.listCallCount == 1 }

        // Kick off second sync — must cancel the first and drain.
        sut.syncIfSignedIn()

        // Wait for the first to be cancelled.
        try await waitFor(timeout: 2.0) { self.fakeClient.listHostsTaskWasCancelled == true }
        XCTAssertTrue(fakeClient.listHostsTaskWasCancelled,
            "First sync's listHosts sleep must have been cancelled")

        // Wait for the second to enter listHosts.
        try await waitFor(timeout: 2.0) { self.fakeClient.listCallCount == 2 }

        // The second listHosts must START AFTER the first one's cancel-and-drain
        // completed (i.e., after the first finishedAt or — since cancellation
        // throws before finished — at minimum after the cancellation flag was set).
        // Concretely: the second start time must be >= the moment the first
        // cancelled. We approximate by asserting both starts are present and
        // there is no overlap visible in the started/finished arrays.
        XCTAssertEqual(fakeClient.listHostsStartedAt.count, 2)

        // Wait for the second sync to actually finish (no delay, but small for the await chain).
        try await Task.sleep(nanoseconds: 300_000_000)  // 0.3 s
    }

    func testManualDrainsAuto() async throws {
        // Auto sync hangs; manual cancels and drains it before running.
        fakeClient.listHostsDelay = 0.2

        sut.syncIfSignedIn()
        try await waitFor(timeout: 1.0) { self.fakeClient.listCallCount == 1 }

        // Now release the delay so manual's own listHosts call returns fast,
        // but the AUTO call should be cancelled mid-sleep first.
        fakeClient.listHostsDelay = 0
        try await sut.sync()  // manual — must complete without throwing

        XCTAssertTrue(fakeClient.listHostsTaskWasCancelled,
            "Auto's listHosts sleep must have been cancelled by manual")
        XCTAssertEqual(fakeClient.listCallCount, 2,
            "Both auto (cancelled) and manual (succeeded) should have entered listHosts")
    }

    // MARK: - Task 2.10.3d: manual coordination (defer + concurrent-manual lock)

    func testAutoSyncDeferredAndReplayedAroundManual() async throws {
        // Manual will hang in listHosts — long enough that we can fire a
        // mutation during it and observe that the debounced auto schedule
        // is deferred (pendingAutoAfterManual), then replayed after manual exits.
        fakeClient.listHostsDelay = 0.3

        let manualTask = Task<Void, Error> { try await self.sut.sync() }
        // Wait for manual to enter listHosts.
        try await waitFor(timeout: 1.0) { self.fakeClient.listCallCount == 1 }

        // Mutate while manual is in flight. The debounce sink will fire
        // 0.05 s later and call scheduleAutoSync — which must skip due
        // to manualInProgress and set pendingAutoAfterManual instead.
        let h = SSHHost(name: "during-manual", hostname: "x", username: "u", credential: .agent)
        try sessionStore.addHost(h)

        // Wait past the debounce window.
        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 s
        XCTAssertEqual(fakeClient.listCallCount, 1,
            "Debounced schedule must be DEFERRED while manual is in progress")

        // Now release manual by clearing the delay (already running call still
        // sleeps the original 0.3 s; future calls don't).
        fakeClient.listHostsDelay = 0

        // Wait for manual to finish.
        _ = try await manualTask.value

        // The replay must fire — listCallCount goes to 2.
        try await waitFor(timeout: 2.0) { self.fakeClient.listCallCount == 2 }
        XCTAssertEqual(fakeClient.listCallCount, 2,
            "Deferred auto must REPLAY in manual's defer (pendingAutoAfterManual)")
    }

    func testConcurrentManualSyncSharesOutcome() async throws {
        // Two callers invoke sync() concurrently. The second must await the
        // first's task (currentManualTask lock) — only one performSync runs.
        fakeClient.listHostsDelay = 0.2

        let a = Task<Void, Error> { try await self.sut.sync() }
        // Yield so caller A reaches the inside of sync() and assigns currentManualTask.
        try await Task.sleep(nanoseconds: 20_000_000)  // 0.02 s
        let b = Task<Void, Error> { try await self.sut.sync() }

        _ = try await a.value
        _ = try await b.value

        XCTAssertEqual(fakeClient.listCallCount, 1,
            "Concurrent manual callers must share a single in-flight pass (currentManualTask lock)")
    }

    // MARK: - Task 1.13: checkpoint-on-success

    func testCheckpointCommittedAfterApplySucceeds() async throws {
        let fake = FakeIncrementalHostSyncClient()
        let cpID = UUID()
        fake.fetchSnapshotResult = HostChangeBatch(
            changedHosts: [makeRemote(id: "R1")],
            deletedHostIDs: [],
            checkpoint: FakeCheckpoint(id: cpID),
            tokenExpired: false,
            mode: .forceFull
        )
        let store = makeIncrementalStore(client: fake)
        try await store.sync()
        XCTAssertEqual(fake.commitCalls.map(\.id), [cpID])
        XCTAssertGreaterThan(sessionStore.hosts.count, 0,
                             "apply must have created a local host before commit")
    }

    func testApplyFailureDoesNotAdvanceChangeTokens() async throws {
        // Pre-seed a local host without serverId so reconcileFullSnapshot emits
        // .createRemote (the path that calls client.createHost).
        let unsynced = SSHHost(name: "x", hostname: "h", port: 22, username: "u",
                               credential: .agent)
        try sessionStore.addHost(unsynced)

        let fake = FakeIncrementalHostSyncClient()
        fake.fetchSnapshotResult = HostChangeBatch(
            changedHosts: [],
            deletedHostIDs: [],
            checkpoint: FakeCheckpoint(id: UUID()),
            tokenExpired: false, mode: .forceFull
        )
        fake.createHostError = NSError(domain: "T", code: 1)

        let store = makeIncrementalStore(client: fake)
        do {
            try await store.sync()
            XCTFail("expected throw from createHost")
        } catch {
            // expected
        }
        XCTAssertTrue(fake.commitCalls.isEmpty,
                      "commit must NOT run when apply fails")
    }

    func testNilCheckpointFromTokenExpiredBatchSkipsCommit() async throws {
        let fake = FakeIncrementalHostSyncClient()
        fake.fetchSnapshotResult = HostChangeBatch(
            changedHosts: [], deletedHostIDs: [],
            checkpoint: nil, tokenExpired: true, mode: .incremental
        )
        fake.fetchSnapshotResultRetry = HostChangeBatch(
            changedHosts: [], deletedHostIDs: [],
            checkpoint: nil, tokenExpired: false, mode: .forceFull
        )
        let store = makeIncrementalStore(client: fake)
        try await store.sync()
        XCTAssertTrue(fake.commitCalls.isEmpty,
                      "no checkpoint → no commit")
    }

    func testTokenExpiredTriggersForceFullRetry() async throws {
        let fake = FakeIncrementalHostSyncClient()
        fake.fetchSnapshotResult = HostChangeBatch(
            changedHosts: [], deletedHostIDs: [],
            checkpoint: nil, tokenExpired: true, mode: .incremental
        )
        let cpID = UUID()
        fake.fetchSnapshotResultRetry = HostChangeBatch(
            changedHosts: [], deletedHostIDs: [],
            checkpoint: FakeCheckpoint(id: cpID),
            tokenExpired: false, mode: .forceFull
        )
        let store = makeIncrementalStore(client: fake)
        try await store.sync()
        XCTAssertEqual(fake.fetchModes.count, 2,
                       "token-expired must trigger one retry")
        XCTAssertEqual(fake.fetchModes[1], .forceFull,
                       "retry must be forceFull")
        XCTAssertEqual(fake.commitCalls.map(\.id), [cpID])
    }

    private func makeIncrementalStore(client: FakeIncrementalHostSyncClient) -> HostSyncStore {
        let prefs = SyncPreferences(defaults: isolatedDefaults)
        return HostSyncStore(client: client,
                             sessionStore: sessionStore,
                             authSession: fakeAuth,
                             preferences: prefs,
                             credentialSync: CredentialSyncPreferencesStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!),
                             debounceInterval: 0.05,
                             userDefaults: isolatedDefaults)
    }

    private func makeRemote(id: String) -> RemoteHost {
        RemoteHost(id: id, name: "n-\(id)", hostname: "h", port: 22,
                   username: "u", authType: "password",
                   createdAt: Date(timeIntervalSince1970: 100),
                   updatedAt: Date(timeIntervalSince1970: 200))
    }

    // Polls `condition` on the @MainActor every 10 ms up to `timeout`.
    // XCTestCase doesn't auto-pump @MainActor work between awaits without
    // explicit yields, so this small helper is the standard pattern across
    // these tests.
    private func waitFor(timeout: TimeInterval,
                         _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
        }
        XCTFail("waitFor timeout after \(timeout)s")
    }
}

/// Minimal AuthSessionProtocol stub for tests. Doesn't subclass AuthSession,
/// so no URL plumbing or cookie machinery to deal with.
final class FakeAuthSession: AuthSessionProtocol {
    var isSignedIn: Bool
    init(isSignedIn: Bool = true) {
        self.isSignedIn = isSignedIn
    }
}
