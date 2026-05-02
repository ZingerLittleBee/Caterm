import XCTest
import KeychainStore
import SSHCommandBuilder
@testable import SessionStore

@MainActor
final class SetHostCredentialMaterialTests: XCTestCase {
	private var hostsURL: URL!
	private var keychain: KeychainStore!
	private var store: SessionStore!

	override func setUp() async throws {
		try await super.setUp()
		hostsURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("hosts-\(UUID()).json")
		keychain = KeychainStore(
			service: "com.caterm.test.set-credential-material.\(UUID())",
			accessGroup: nil
		)
		store = SessionStore(
			askpassPath: "/x", knownHostsCaterm: "/A",
			knownHostsUser: "/B", accessGroup: nil,
			hostsURL: hostsURL, keychain: keychain
		)
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: hostsURL)
		try? keychain?.deleteAll(prefix: "")
		try await super.tearDown()
	}

	func test_setMaterial_writesKeychain_setsDirty_postsNotification() async throws {
		var host = Host(name: "Box", hostname: "h", port: 22, username: "u", credential: .password)
		try store.addHost(host)
		host = store.hosts.first { $0.id == host.id }!

		let exp = expectation(forNotification: .catermHostCredentialMaterialChanged, object: nil) { note in
			(note.userInfo?[CatermHostCredentialMaterialChangedKeys.hostId] as? UUID) == host.id
		}

		try store.setHostCredentialMaterial(
			secrets: HostSecrets(password: Data("p".utf8)),
			credentialSource: .password,
			for: host.id
		)

		await fulfillment(of: [exp], timeout: 1.0)
		let stored = try keychain.get(account: "\(host.id.uuidString).password")
		XCTAssertEqual(stored, "p")
		XCTAssertTrue(store.hosts.first { $0.id == host.id }!.credentialMaterialDirty)
	}

	func test_clearDirty_isIdempotent_andPersists() async throws {
		var host = Host(name: "Box", hostname: "h", port: 22, username: "u", credential: .password)
		host.credentialMaterialDirty = true
		try store.addHost(host)
		try store.clearCredentialMaterialDirty(host.id)
		try store.clearCredentialMaterialDirty(host.id)  // idempotent
		XCTAssertFalse(store.hosts.first { $0.id == host.id }!.credentialMaterialDirty)
	}
}
