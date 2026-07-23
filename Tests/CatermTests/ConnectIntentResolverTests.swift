import XCTest
@testable import Caterm
@testable import SessionStore
@testable import SSHCommandBuilder
@testable import KeychainStore

@MainActor
final class ConnectIntentResolverTests: XCTestCase {
    var sut: SessionStore!
    var tmpHostsURL: URL!
    var ephemeralService: String!

    override func setUp() async throws {
        ephemeralService = "com.caterm.test.\(UUID().uuidString)"
        tmpHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-resolver-\(UUID()).json")
        let kc = KeychainStore(service: ephemeralService, accessGroup: nil)
        sut = SessionStore(
            askpassPath: "/x", knownHostsCaterm: "/A",
            knownHostsUser: "/B", accessGroup: nil,
            hostsURL: tmpHostsURL, keychain: kc
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpHostsURL)
        if let kc = sut?.keychain {
            try? kc.deleteAll(prefix: "")
        }
    }

    /// Synced-down host with `.password` credential and no Keychain entry
    /// must gate to `.promptCredentials`. Mirrors what `addRemoteHost`
    /// produces during a Sync Now pull.
	func testLockedHostResolvesToPromptCredentials() async throws {
        let host = SSHHost(
            id: UUID(),
            serverId: "srv-1",
            name: "remote", hostname: "h", port: 22, username: "u",
            credential: .password
        )
        try await sut.addHost(host)

		let intent = await resolveConnectIntent(for: host, in: sut)
		XCTAssertEqual(intent, .promptCredentials)
    }

	func testUnlockedAgentHostResolvesToOpenTab() async throws {
        let host = SSHHost(name: "agent-host", hostname: "h", port: 22,
                           username: "u", credential: .agent)
        try await sut.addHost(host)

		let intent = await resolveConnectIntent(for: host, in: sut)
		XCTAssertEqual(intent, .openTab)
    }

    /// End-to-end pinning: starting from a locked host, performing the
    /// Save sequence (Keychain first, setCredentialOnly second) must
    /// transition the resolver from .promptCredentials to .openTab.
	func testCredentialSetupTransitionsLockedToUnlocked() async throws {
        let host = SSHHost(
            id: UUID(),
            serverId: "srv-2",
            name: "remote2", hostname: "h", port: 22, username: "u",
            credential: .password
        )
        try await sut.addHost(host)
		let lockedIntent = await resolveConnectIntent(for: host, in: sut)
		XCTAssertEqual(lockedIntent, .promptCredentials)

        try sut.setHostSecret("p@ss", hostId: host.id, kind: .password)
        try await sut.setCredentialOnly(.password, for: host.id)

        let refreshed = sut.hosts.first { $0.id == host.id }!
		let unlockedIntent = await resolveConnectIntent(for: refreshed, in: sut)
		XCTAssertEqual(unlockedIntent, .openTab)
    }
}
