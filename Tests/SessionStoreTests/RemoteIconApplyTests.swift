import XCTest
import KeychainStore
import SSHCommandBuilder
import ServerSyncClient
@testable import SessionStore

/// Verifies the cross-device scenario: machine A set a host icon (synced
/// up); machine B (no icon locally) pulls it down. Exercises the pull-side
/// SessionStore entry points the reconciler drives.
@MainActor
final class RemoteIconApplyTests: XCTestCase {
	private var hostsURL: URL!
	private var keychain: KeychainStore!
	private var store: SessionStore!

	override func setUp() async throws {
		try await super.setUp()
		hostsURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("hosts-icon-apply-\(UUID()).json")
		keychain = KeychainStore(
			service: "com.caterm.test.remote-icon-apply.\(UUID())",
			accessGroup: nil
		)
		store = SessionStore(
			askpassPath: "/dev/null", knownHostsCaterm: "/dev/null",
			knownHostsUser: "/dev/null", accessGroup: nil,
			hostsURL: hostsURL, keychain: keychain
		)
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: hostsURL)
		try? keychain?.deleteAll(prefix: "")
		try await super.tearDown()
	}

	func test_applyRemoteMetadata_copiesIconOntoIconlessHost() throws {
		// Machine B's local copy has no icon.
		let host = SSHHost(serverId: "rid", name: "h", hostname: "h.example",
		                    port: 22, username: "u", credential: .password)
		try store.addHost(host)
		XCTAssertNil(store.hosts.first(where: { $0.id == host.id })?.icon)

		let remote = RemoteHost(
			id: "rid", name: host.name, hostname: host.hostname,
			port: host.port, username: host.username, authType: "key",
			createdAt: host.createdAt, updatedAt: Date(),
			icon: "server.rack"
		)
		try store.applyRemoteMetadata(localHostId: host.id, remote: remote)
		XCTAssertEqual(
			store.hosts.first(where: { $0.id == host.id })?.icon, "server.rack")
	}

	func test_addRemoteHost_carriesIcon() throws {
		let remote = RemoteHost(
			id: "rid", name: "h", hostname: "h.example", port: 22,
			username: "u", authType: "key",
			createdAt: Date(), updatedAt: Date(),
			icon: "globe.americas.fill"
		)
		try store.addRemoteHost(remote)
		XCTAssertEqual(
			store.hosts.first(where: { $0.serverId == "rid" })?.icon,
			"globe.americas.fill")
	}

	func test_applyRemoteMetadata_clearsIconWhenRemoteHasNone() throws {
		var host = SSHHost(serverId: "rid", name: "h", hostname: "h.example",
		                   port: 22, username: "u", credential: .password)
		host.icon = "flag.fill"
		try store.addHost(host)
		let remote = RemoteHost(
			id: "rid", name: host.name, hostname: host.hostname,
			port: host.port, username: host.username, authType: "key",
			createdAt: host.createdAt, updatedAt: Date(), icon: nil
		)
		try store.applyRemoteMetadata(localHostId: host.id, remote: remote)
		XCTAssertNil(store.hosts.first(where: { $0.id == host.id })?.icon)
	}
}
