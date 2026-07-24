import CredentialSyncStore
import XCTest
@testable import HostSyncStore
@testable import SessionStore
@testable import SSHCommandBuilder
@testable import ServerSyncClient
@testable import KeychainStore

/// C2 regression: `forwards` must be pushed through `RemoteHostCreateInput`
/// and `RemoteHostUpdateInput` on the self-hosted server path. CloudKit sync
/// covers forwards separately; the self-hosted DTO path used to drop them
/// silently because `apply(.createRemote)` / `apply(.updateRemote)` omitted
/// the field at the call site.
@MainActor
final class PortForwardPushTests: XCTestCase {
    var sut: HostSyncStore!
    var fakeClient: FakeServerSyncClient!
    var sessionStore: SessionStore!
    var tmpHostsURL: URL!
    var isolatedDefaults: UserDefaults!

    override func setUp() async throws {
        tmpHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-pf-push-\(UUID()).json")
        let kc = KeychainStore(service: "com.caterm.test.\(UUID().uuidString)",
                               accessGroup: nil)
        sessionStore = SessionStore(askpassPath: "/x", knownHostsCaterm: "/A",
                                    knownHostsUser: "/B", accessGroup: nil,
                                    hostsURL: tmpHostsURL, keychain: kc)
        fakeClient = FakeServerSyncClient()
        isolatedDefaults = UserDefaults(suiteName: "caterm-test-\(UUID().uuidString)")!
        let prefs = SyncPreferences(defaults: isolatedDefaults)
        sut = HostSyncStore(
            client: fakeClient,
            sessionStore: sessionStore,
            authSession: FakeAuthSession(isSignedIn: true),
            preferences: prefs,
            credentialSync: CredentialSyncPreferencesStore(
                defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!
            ),
            userDefaults: isolatedDefaults
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpHostsURL)
    }

    private func makeForward(bindPort: Int, label: String) -> PortForward {
        PortForward(
            kind: .local,
            bindPort: bindPort,
            remoteHost: "127.0.0.1",
            remotePort: 5432,
            required: true,
            label: label
        )
    }

    func testCreateRemotePushesForwards() async throws {
        let forwards = [
            makeForward(bindPort: 15_432, label: "pg"),
            makeForward(bindPort: 16_379, label: "redis"),
        ]
        let host = SSHHost(
            name: "alpha", hostname: "x", username: "u",
            credential: .agent, forwards: forwards,
            organization: HostOrganization(
                groupPath: ["Production"], tags: ["Linux"]
            )
        )
        try await sessionStore.addHost(host)
        // Server empty -> reconciler emits .createRemote for this host.
        fakeClient.listResult = []
        fakeClient.createResult = RemoteHostCreateOutput(id: "srv-new")

        try await sut.sync()

        XCTAssertEqual(fakeClient.createHostInputs.count, 1)
        let pushed = try XCTUnwrap(fakeClient.createHostInputs.first)
        XCTAssertEqual(pushed.forwards.count, 2)
        XCTAssertEqual(Set(pushed.forwards.map(\.bindPort)), [15_432, 16_379])
        XCTAssertEqual(Set(pushed.forwards.compactMap(\.label)), ["pg", "redis"])
        XCTAssertEqual(pushed.organization, host.organization)
        XCTAssertEqual(pushed.metadataUpdatedAt, host.updatedAt)
    }

    func testUpdateRemotePushesForwards() async throws {
        let remoteUpdatedAt = Date(timeIntervalSince1970: 1_000_000)
        let localUpdatedAt = remoteUpdatedAt.addingTimeInterval(60) // local wins
        let forwards = [makeForward(bindPort: 18_080, label: "http")]
        var host = SSHHost(
            name: "alpha", hostname: "x", username: "u",
            credential: .agent,
            updatedAt: localUpdatedAt,
            forwards: forwards,
            organization: HostOrganization(
                groupPath: ["Staging"], tags: ["On-call"]
            )
        )
        host.serverId = "srv-1"
        try await sessionStore.addHost(host)
        // Same server row, older timestamp -> reconciler emits .updateRemote.
        fakeClient.listResult = [
            RemoteHost(
                id: "srv-1", name: "alpha", hostname: "x", port: 22,
                username: "u", authType: "key",
                createdAt: remoteUpdatedAt, updatedAt: remoteUpdatedAt,
                forwards: []
            )
        ]

        try await sut.sync()

        XCTAssertEqual(fakeClient.updateHostInputs.count, 1)
        let pushed = try XCTUnwrap(fakeClient.updateHostInputs.first)
        XCTAssertEqual(pushed.id, "srv-1")
        XCTAssertEqual(pushed.forwards?.count, 1)
        XCTAssertEqual(pushed.forwards?.first?.bindPort, 18_080)
        XCTAssertEqual(pushed.forwards?.first?.label, "http")
        XCTAssertEqual(pushed.organization, host.organization)
        XCTAssertEqual(pushed.metadataUpdatedAt, host.updatedAt)
    }
}
