import Combine
import XCTest
@testable import HostSyncStore
@testable import SessionStore
@testable import SSHCommandBuilder
@testable import ServerSyncClient
@testable import KeychainStore

@MainActor
final class HostSyncStorePeriodicTests: XCTestCase {
    var sut: HostSyncStore!
    var fakeClient: FakeServerSyncClient!
    var fakeAuth: FakeAuthSession!
    var sessionStore: SessionStore!
    var prefs: SyncPreferences!
    var isolatedDefaults: UserDefaults!
    var tmpHostsURL: URL!

    override func setUp() async throws {
        tmpHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-periodic-\(UUID()).json")
        let kc = KeychainStore(service: "com.caterm.test.\(UUID().uuidString)",
                               accessGroup: nil)
        sessionStore = SessionStore(askpassPath: "/x", knownHostsCaterm: "/A",
                                     knownHostsUser: "/B", accessGroup: nil,
                                     hostsURL: tmpHostsURL, keychain: kc)
        fakeClient = FakeServerSyncClient()
        fakeAuth = FakeAuthSession(isSignedIn: true)
        isolatedDefaults = UserDefaults(suiteName: "caterm-test-\(UUID().uuidString)")!
        prefs = SyncPreferences(defaults: isolatedDefaults)
        // Production interval (15 min) is fine for tests that don't
        // exercise the timer — they finish in milliseconds.
        sut = HostSyncStore(client: fakeClient,
                            sessionStore: sessionStore,
                            authSession: fakeAuth,
                            preferences: prefs,
                            debounceInterval: 0.05,
                            userDefaults: isolatedDefaults)
    }

    override func tearDown() async throws {
        sut = nil
        try? FileManager.default.removeItem(at: tmpHostsURL)
    }

    // MARK: - lastSyncedAt freshness (spec §4.2)

    func testLastSyncedAtNilBeforeAnySync() {
        XCTAssertNil(sut.lastSyncedAt,
            "Fresh isolated defaults: no prior sync recorded")
    }

    func testLastSyncedAtUpdatesAfterSuccessfulSync() async throws {
        try await sut.sync()
        XCTAssertNotNil(sut.lastSyncedAt, "Manual sync success must update lastSyncedAt")
        XCTAssertNotNil(isolatedDefaults.object(forKey: "catermLastSyncedAt") as? Date,
            "Successful sync must persist lastSyncedAt to UserDefaults")
    }

    func testLastSyncedAtPersistsAcrossInstances() async throws {
        try await sut.sync()
        let recordedDate = sut.lastSyncedAt!
        sut = nil   // simulate app quit

        // Build a fresh HostSyncStore over the same defaults — hydrate path.
        let newPrefs = SyncPreferences(defaults: isolatedDefaults)
        let newSut = HostSyncStore(client: fakeClient,
                                   sessionStore: sessionStore,
                                   authSession: fakeAuth,
                                   preferences: newPrefs,
                                   debounceInterval: 0.05,
                                   userDefaults: isolatedDefaults)

        XCTAssertNotNil(newSut.lastSyncedAt, "Hydrate from UserDefaults on init")
        XCTAssertEqual(newSut.lastSyncedAt!.timeIntervalSince1970,
                       recordedDate.timeIntervalSince1970,
                       accuracy: 0.001,
                       "Hydrated date should match the persisted date within 1 ms")
    }

    func testLastSyncedAtUnchangedOnError() async throws {
        struct Boom: Error {}
        fakeClient.listHostsError = Boom()
        do {
            try await sut.sync()
            XCTFail("listHosts threw — sync should have re-thrown")
        } catch {
            // expected
        }
        XCTAssertNil(sut.lastSyncedAt,
            "list-failure path must NOT advance lastSyncedAt (spec §4.2)")
        XCTAssertNil(isolatedDefaults.object(forKey: "catermLastSyncedAt") as? Date,
            "list-failure path must NOT persist a stale date")
    }

    func testLastSyncedAtUnchangedOnPartialApplyFailure() async throws {
        struct Boom: Error {}
        // listHosts succeeds (default empty), but createHost throws.
        // Seed a local-only host so reconciler emits a .createRemote op.
        let h = SSHHost(name: "alpha", hostname: "x", username: "u", credential: .agent)
        try sessionStore.addHost(h)
        fakeClient.listResult = []
        fakeClient.createHostError = Boom()

        // sync() will throw inside the apply loop; lastSyncedAt update sits
        // AFTER the loop, so it must not have run.
        do {
            try await sut.sync()
            XCTFail("createHost threw — sync should have re-thrown")
        } catch {
            // expected
        }

        XCTAssertNil(sut.lastSyncedAt,
            "Partial-apply failure must NOT advance lastSyncedAt — pins §4.2's apply-loop carve-out")
        XCTAssertNil(isolatedDefaults.object(forKey: "catermLastSyncedAt") as? Date,
            "Partial-apply failure must NOT persist a stale date")
    }

    // MARK: - Auth gate on scheduleAutoSync (spec §3.2 / §4.4.1)

    func testSignedOutMutationDebounceNoOps() async throws {
        fakeAuth.isSignedIn = false
        let h = SSHHost(name: "alpha", hostname: "x", username: "u", credential: .agent)
        try sessionStore.addHost(h)
        // Wait past 3× the debounce window.
        try await Task.sleep(nanoseconds: 200_000_000)  // 0.2 s
        XCTAssertEqual(fakeClient.listCallCount, 0,
            "Mutation-debounce must no-op when signed out (scheduleAutoSync auth gate, spec §3.2)")
    }

    // MARK: - Periodic timer (spec §3.2 handlePeriodicEnabled)

    func testTogglingDisabledStopsFutureFires() async throws {
        // Use a fast interval so we observe a fire within milliseconds.
        let fastSut = HostSyncStore(client: fakeClient,
                                    sessionStore: sessionStore,
                                    authSession: fakeAuth,
                                    preferences: prefs,
                                    debounceInterval: 0.05,
                                    periodicInterval: 0.05,
                                    userDefaults: isolatedDefaults)
        _ = fastSut  // retain
        // Wait for the first periodic fire.
        try await waitFor(timeout: 1.0) { self.fakeClient.listCallCount == 1 }
        let countAfterFirstFire = fakeClient.listCallCount
        prefs.periodicSyncEnabled = false
        // Wait 3× the interval for any future fires (none should arrive).
        try await Task.sleep(nanoseconds: 200_000_000)  // 0.2 s
        XCTAssertEqual(fakeClient.listCallCount, countAfterFirstFire,
            "Toggling off must cancel the periodic timer (spec §4.4 invariant 2)")
    }

    func testTogglingEnabledRestartsTimer() async throws {
        // Start with toggle off so the timer never starts.
        let suite = "caterm-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "catermPeriodicSyncEnabled")
        let offPrefs = SyncPreferences(defaults: defaults)
        XCTAssertFalse(offPrefs.periodicSyncEnabled, "Sanity: off is read back from defaults")

        let toggleSut = HostSyncStore(client: fakeClient,
                                      sessionStore: sessionStore,
                                      authSession: fakeAuth,
                                      preferences: offPrefs,
                                      debounceInterval: 0.05,
                                      periodicInterval: 0.05,
                                      userDefaults: defaults)
        _ = toggleSut  // retain

        // Wait one interval — no fire should occur because toggle is off.
        try await Task.sleep(nanoseconds: 200_000_000)  // 0.2 s
        XCTAssertEqual(fakeClient.listCallCount, 0,
            "Toggle off at init: no timer, no fires")

        // Flip toggle on — timer should start; one fire within ~1 interval.
        offPrefs.periodicSyncEnabled = true
        try await waitFor(timeout: 1.0) { self.fakeClient.listCallCount >= 1 }
        XCTAssertGreaterThanOrEqual(fakeClient.listCallCount, 1,
            "Flipping toggle on must (re)start the timer (spec §4.4 invariant 3)")
    }

    func testSignedOutPeriodicTimerNoOps() async throws {
        fakeAuth.isSignedIn = false
        let fastSut = HostSyncStore(client: fakeClient,
                                    sessionStore: sessionStore,
                                    authSession: fakeAuth,
                                    preferences: prefs,
                                    debounceInterval: 0.05,
                                    periodicInterval: 0.05,
                                    userDefaults: isolatedDefaults)
        _ = fastSut  // retain
        // Wait 3× the interval. The timer fires, but scheduleAutoSync's
        // auth gate must short-circuit before any network call.
        try await Task.sleep(nanoseconds: 200_000_000)  // 0.2 s
        XCTAssertEqual(fakeClient.listCallCount, 0,
            "Signed-out periodic timer fires must hit the auth gate, not the network (spec §3.2)")
    }

    // MARK: - Wake-from-sleep (spec §3.2 handleSystemWake)

    func testDidWakeNotificationTriggersSync() async throws {
        // Toggle is on (default), authSession is signedIn (default).
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil)
        try await waitFor(timeout: 1.0) { self.fakeClient.listCallCount == 1 }
        XCTAssertEqual(fakeClient.listCallCount, 1,
            "Wake notification must fire scheduleAutoSync (spec §3.2)")
    }

    func testTogglingDisabledStopsWakeFires() async throws {
        prefs.periodicSyncEnabled = false
        // Allow the @Published sink to propagate the disabled state.
        try await Task.sleep(nanoseconds: 50_000_000)  // 0.05 s
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil)
        try await Task.sleep(nanoseconds: 200_000_000)  // 0.2 s
        XCTAssertEqual(fakeClient.listCallCount, 0,
            "Wake handler must honor preferences.periodicSyncEnabled (spec §4.4)")
    }

    func testSignedOutWakeNoOps() async throws {
        fakeAuth.isSignedIn = false
        // Toggle stays on so wake handler reaches scheduleAutoSync;
        // the auth gate inside scheduleAutoSync is the short-circuit.
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil)
        try await Task.sleep(nanoseconds: 200_000_000)  // 0.2 s
        XCTAssertEqual(fakeClient.listCallCount, 0,
            "Wake fire when signed out must short-circuit at the auth gate (spec §3.2 / §4.4.1)")
    }

    // Polls `condition` on the @MainActor every 10 ms up to `timeout`.
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
