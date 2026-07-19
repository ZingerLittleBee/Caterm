import Combine
import ManagedKeyStore
import XCTest
@testable import SessionStore
@testable import SSHCommandBuilder
@testable import ServerSyncClient
@testable import KeychainStore

@MainActor
final class SessionStoreMutationPublisherTests: XCTestCase {
    var sut: SessionStore!
    var tmpHostsURL: URL!
    var cancellables: Set<AnyCancellable>!

    override func setUp() async throws {
        cancellables = []
        tmpHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-pub-\(UUID()).json")
        let kc = KeychainStore(service: "com.caterm.test.\(UUID().uuidString)",
                               accessGroup: nil)
		let managedKeys = ManagedKeyStore(
			rootURL: tmpHostsURL.deletingLastPathComponent()
				.appendingPathComponent("caterm-pub-keys-\(UUID())")
		)
        let materialStore = SessionCredentialMaterialStore(
			secrets: InMemoryCredentialSecretStore(),
			managedKeyStore: managedKeys
        )
        sut = SessionStore(askpassPath: "/x", knownHostsCaterm: "/A",
                           knownHostsUser: "/B", accessGroup: nil,
                           hostsURL: tmpHostsURL, keychain: kc,
						   managedKeyStore: managedKeys,
                           credentialMaterialStore: materialStore)
    }

    override func tearDown() async throws {
        cancellables = nil
        try? FileManager.default.removeItem(at: tmpHostsURL)
    }

    func testAddHostEmits() throws {
        var received = 0
        sut.mutationsForSync.sink { _ in received += 1 }
            .store(in: &cancellables)

        let h = SSHHost(name: "alpha", hostname: "x", username: "u", credential: .agent)
        try sut.addHost(h)

        XCTAssertEqual(received, 1)
    }

    func testUpdateHostEmits() throws {
        var h = SSHHost(name: "alpha", hostname: "x", username: "u", credential: .agent)
        try sut.addHost(h)  // baseline (before subscribe — not counted)

        var received = 0
        sut.mutationsForSync.sink { _ in received += 1 }
            .store(in: &cancellables)

        h.name = "alpha-renamed"
        try sut.updateHost(h)

        XCTAssertEqual(received, 1)
    }

    func testDeleteHostEmits() async throws {
        let h = SSHHost(name: "alpha", hostname: "x", username: "u", credential: .agent)
        try sut.addHost(h)  // baseline

        var received = 0
        sut.mutationsForSync.sink { _ in received += 1 }
            .store(in: &cancellables)

        try await sut.deleteHost(id: h.id)

        XCTAssertEqual(received, 1)
    }

    func testSetCredentialOnlyDoesNotEmit() throws {
        let h = SSHHost(name: "alpha", hostname: "x", username: "u", credential: .agent)
        try sut.addHost(h)  // baseline

        var received = 0
        sut.mutationsForSync.sink { _ in received += 1 }
            .store(in: &cancellables)

        try sut.setCredentialOnly(.password, for: h.id)

        XCTAssertEqual(received, 0,
            "Credential is a device-local overlay; must not trigger sync (spec §3.2)")
    }

    func testRemoteApplyDoesNotEmit() throws {
        var received = 0
        sut.mutationsForSync.sink { _ in received += 1 }
            .store(in: &cancellables)

        let now = Date()
        let remote = RemoteHost(id: "srv-1", name: "alpha", hostname: "x",
                                port: 22, username: "u", authType: "key",
                                createdAt: now, updatedAt: now)
        try sut.addRemoteHost(remote)

        // applyRemoteMetadata + setServerId on the just-added pulled host
        let pulled = sut.hosts.first(where: { $0.serverId == "srv-1" })!
        try sut.applyRemoteMetadata(localHostId: pulled.id, remote: remote)
        try sut.setServerId("srv-1", for: pulled.id)

        XCTAssertEqual(received, 0,
            "Remote-apply ops are sync OUTPUTS; emitting would create echo loop (spec §3.2)")
    }
}
