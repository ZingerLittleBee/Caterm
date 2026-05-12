import XCTest
import KeychainStore
import SSHCommandBuilder
import ServerSyncClient
@testable import SessionStore

@MainActor
final class RemoteForwardsApplyTests: XCTestCase {
	private var hostsURL: URL!
	private var keychain: KeychainStore!
	private var store: SessionStore!

	override func setUp() async throws {
		try await super.setUp()
		hostsURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("hosts-fwd-apply-\(UUID()).json")
		keychain = KeychainStore(
			service: "com.caterm.test.remote-forwards-apply.\(UUID())",
			accessGroup: nil
		)
		store = SessionStore(
			askpassPath: "/dev/null",
			knownHostsCaterm: "/dev/null",
			knownHostsUser: "/dev/null",
			accessGroup: nil,
			hostsURL: hostsURL,
			keychain: keychain
		)
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: hostsURL)
		try? keychain?.deleteAll(prefix: "")
		try await super.tearDown()
	}

	private func addLocalHost(forwards: [PortForward]) throws -> SSHHost {
		let host = SSHHost(
			serverId: nil,
			name: "h", hostname: "h.example", port: 22,
			username: "u", credential: .password,
			forwards: forwards
		)
		try store.addHost(host)
		return store.hosts.first(where: { $0.id == host.id })!
	}

	func test_applyRemoteMetadata_copiesForwards() throws {
		let host = try addLocalHost(forwards: [])
		let remote = RemoteHost(
			id: "rid",
			name: host.name,
			hostname: host.hostname,
			port: host.port,
			username: host.username,
			authType: "key",
			createdAt: host.createdAt,
			updatedAt: Date(),
			forwards: [
				PortForward(kind: .local, bindPort: 5432,
				            remoteHost: "db", remotePort: 5432),
			]
		)
		try store.applyRemoteMetadata(localHostId: host.id, remote: remote)
		XCTAssertEqual(
			store.hosts.first(where: { $0.id == host.id })?.forwards.count, 1)
		XCTAssertEqual(
			store.hosts.first(where: { $0.id == host.id })?.forwards.first?.bindPort,
			5432)
	}

	func test_addRemoteHost_carriesForwards() throws {
		let remote = RemoteHost(
			id: "rid", name: "h", hostname: "h.example", port: 22,
			username: "u", authType: "key",
			createdAt: Date(), updatedAt: Date(),
			forwards: [PortForward(kind: .dynamic, bindPort: 1080)]
		)
		try store.addRemoteHost(remote)
		let saved = store.hosts.first(where: { $0.serverId == "rid" })
		XCTAssertNotNil(saved)
		XCTAssertEqual(saved?.forwards.first?.kind, .dynamic)
		XCTAssertEqual(saved?.forwards.first?.bindPort, 1080)
	}
}
