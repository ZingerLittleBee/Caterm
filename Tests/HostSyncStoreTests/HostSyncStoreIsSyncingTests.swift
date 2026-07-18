import Combine
import CredentialSyncStore
import XCTest
@testable import HostSyncStore
@testable import SessionStore
@testable import SSHCommandBuilder
@testable import ServerSyncClient
@testable import KeychainStore

@MainActor
final class HostSyncStoreIsSyncingTests: XCTestCase {
    private enum SyncTestError: Error { case boom }

    var sut: HostSyncStore!
    var fakeClient: FakeServerSyncClient!
    var fakeAuth: FakeAuthSession!
    var sessionStore: SessionStore!
    var prefs: SyncPreferences!
    var isolatedDefaults: UserDefaults!
    var tmpHostsURL: URL!
    private var defaultsSuiteName: String!

    override func setUp() async throws {
        tmpHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-issyncing-\(UUID()).json")
        let kc = KeychainStore(service: "com.caterm.test.\(UUID().uuidString)",
                               accessGroup: nil)
        sessionStore = SessionStore(askpassPath: "/x", knownHostsCaterm: "/A",
                                     knownHostsUser: "/B", accessGroup: nil,
                                     hostsURL: tmpHostsURL, keychain: kc)
        fakeClient = FakeServerSyncClient()
        fakeAuth = FakeAuthSession(isSignedIn: true)
        defaultsSuiteName = "caterm-test-\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        isolatedDefaults.set(true, forKey: "catermPeriodicSyncEnabled")
        prefs = SyncPreferences(defaults: isolatedDefaults)
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
        if let defaultsSuiteName {
            isolatedDefaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        isolatedDefaults = nil
        prefs = nil
        fakeAuth = nil
        fakeClient = nil
        sessionStore = nil
        tmpHostsURL = nil
        defaultsSuiteName = nil
    }

    // MARK: - Initial state

    func testIsSyncingFalseInitially() {
        XCTAssertFalse(sut.isSyncing,
            "Brand-new store has no in-flight sync (spec §2.1.1)")
    }

    // MARK: - Manual sync transitions

    func testIsSyncingTrueDuringManualSync() async throws {
        fakeClient.listHostsDelay = 0.2
        let task = Task { try? await sut.sync() }
        // Yield long enough for the sync task to enter startSync()
        try await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
        XCTAssertTrue(sut.isSyncing,
            "isSyncing must be true while listHosts() is parked on the delay")
        await task.value
        XCTAssertFalse(sut.isSyncing,
            "isSyncing must clear after sync resolves")
    }

    func testIsSyncingFalseAfterManualSyncThrow() async throws {
        fakeClient.listHostsError = SyncTestError.boom
        _ = try? await sut.sync()
        XCTAssertFalse(sut.isSyncing,
            "defer in startSync() must clear isSyncing even when performSync throws (spec §2.1.2)")
    }

    func testSharedManualTaskDoesNotDoubleToggle() async throws {
        fakeClient.listHostsDelay = 0.2
        // Two concurrent callers share the same currentManualTask. Underlying
        // startSync() runs once. isSyncing transitions F → T → F exactly once.
        var observedTrue = 0
        var cancellable: AnyCancellable?
        cancellable = sut.$isSyncing.sink { value in
            if value { observedTrue += 1 }
        }
        async let a: Void? = try? await sut.sync()
        async let b: Void? = try? await sut.sync()
        _ = await (a, b)
        cancellable?.cancel()
        XCTAssertEqual(observedTrue, 1,
            "Two awaiters share one underlying sync; isSyncing flips T exactly once")
        XCTAssertFalse(sut.isSyncing)
    }

    // MARK: - Generation gate (chained cancel-and-drain)

    func testSchedulerKeepsIsSyncingTrueAcrossChainedCancel() async throws {
        // First sync parks in listHosts().
        fakeClient.listHostsDelay = 0.5
        let h1 = SSHHost(name: "alpha", hostname: "x", username: "u", credential: .agent)
        try sessionStore.addHost(h1)
        // Wait past debounce + small margin so the first sync is in flight.
        try await Task.sleep(nanoseconds: 150_000_000)  // 0.15 s (> 0.05 debounce)
        XCTAssertTrue(sut.isSyncing,
            "First auto-sync should be in flight")

        // Trigger another auto-sync — startSync() chains, cancels first, drains.
        let h2 = SSHHost(name: "beta", hostname: "y", username: "u", credential: .agent)
        try sessionStore.addHost(h2)
        // Wait long enough for the second sync to take over but well before
        // the 0.5 s listHostsDelay completes.
        try await Task.sleep(nanoseconds: 200_000_000)  // 0.2 s
        XCTAssertTrue(sut.isSyncing,
            "isSyncing must stay true across the chained cancel-and-drain handoff " +
            "— prior task's defer must NOT clear it (generation gate, spec Decision #22)")

        // Let the second sync finish.
        try await Task.sleep(nanoseconds: 600_000_000)  // 0.6 s
        XCTAssertFalse(sut.isSyncing,
            "The scheduler clears isSyncing only after the latest task exits")
    }
}
