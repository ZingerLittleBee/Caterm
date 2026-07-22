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

	func testAddHostPersistenceFailureDoesNotPublishInMemoryHost() throws {
		try FileManager.default.createDirectory(
			at: tmpHostsURL,
			withIntermediateDirectories: false
		)
		var received = 0
		sut.mutationsForSync.sink { _ in received += 1 }
			.store(in: &cancellables)
		let host = SSHHost(
			name: "unpersisted",
			hostname: "example.invalid",
			username: "tester",
			credential: .agent
		)

		XCTAssertThrowsError(try sut.addHost(host))

		XCTAssertTrue(sut.hosts.isEmpty)
		XCTAssertEqual(received, 0)
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

    func testUpdateHostsPersistsBatchAndEmitsOnce() throws {
        let originalCredential = CredentialSource.keyFile(
            keyPath: "/tmp/id_ed25519",
            hasPassphrase: true
        )
        var alpha = SSHHost(
            name: "alpha",
            hostname: "alpha.example.com",
            username: "root",
            credential: originalCredential
        )
        var beta = SSHHost(
            name: "beta",
            hostname: "beta.example.com",
            username: "root",
            credential: .agent
        )
        try sut.addHost(alpha)
        try sut.addHost(beta)

        var received = 0
        sut.mutationsForSync.sink { _ in received += 1 }
            .store(in: &cancellables)

        alpha.organization = HostOrganization(
            groupPath: ["Production", "API"],
            tags: ["Critical"]
        )
        alpha.credential = .password
        beta.organization = HostOrganization(
            groupPath: ["Production", "Data"],
            tags: ["Database"]
        )

        try sut.updateHosts([alpha, beta])

        let persisted = try HostPersistence.load(from: tmpHostsURL)
        XCTAssertEqual(persisted.count, 2)
        XCTAssertEqual(persisted[0].organization, alpha.organization)
        XCTAssertEqual(persisted[1].organization, beta.organization)
        XCTAssertEqual(persisted[0].credential, originalCredential)
        XCTAssertEqual(persisted[0].updatedAt, persisted[1].updatedAt)
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
