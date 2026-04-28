import Combine
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
        sut = HostSyncStore(client: fakeClient,
                            sessionStore: sessionStore,
                            authSession: fakeAuth,
                            debounceInterval: 0.05)
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
