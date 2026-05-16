import XCTest
import KeychainStore
import SSHCommandBuilder
@testable import SessionStore

@MainActor
final class ApplyRemoteCredentialTests: XCTestCase {
	private var hostsURL: URL!
	private var keychain: KeychainStore!
	private var store: SessionStore!

	override func setUp() async throws {
		try await super.setUp()
		hostsURL = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID()).json")
		keychain = KeychainStore(
			service: "com.caterm.test.apply-remote-credential.\(UUID())",
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

	func test_applyPassword_setsKeychain_keepsCredentialPassword() throws {
		var host = Host(name: "B", hostname: "h", port: 22, username: "u", credential: .password)
		try store.addHost(host)
		host = store.hosts.first { $0.id == host.id }!
		try store.applyRemoteCredential(
			decryptedPassword: Data("p".utf8),
			decryptedPassphrase: nil,
			decryptedPrivateKey: nil,
			managedKeyPath: nil,
			for: host.id
		)
		let stored = try keychain.get(account: "\(host.id.uuidString).password")
		XCTAssertEqual(stored, "p")
		XCTAssertEqual(store.hosts.first { $0.id == host.id }!.credential, .password)
	}

	func test_applyPrivateKey_flipsCredentialToKeyFile() throws {
		var host = Host(name: "B", hostname: "h", port: 22, username: "u", credential: .password)
		try store.addHost(host)
		host = store.hosts.first { $0.id == host.id }!
		try store.applyRemoteCredential(
			decryptedPassword: nil,
			decryptedPassphrase: Data("ppp".utf8),
			decryptedPrivateKey: Data("PEM_BYTES".utf8),
			managedKeyPath: "/var/managed/\(host.id.uuidString)",
			for: host.id
		)
		let stored = try keychain.get(account: "\(host.id.uuidString).keyPassphrase")
		XCTAssertEqual(stored, "ppp")
		let cred = store.hosts.first { $0.id == host.id }!.credential
		if case let .keyFile(path, hasPassphrase) = cred {
			XCTAssertEqual(path, "/var/managed/\(host.id.uuidString)")
			XCTAssertTrue(hasPassphrase)
		} else { XCTFail("expected .keyFile, got \(cred)") }
	}

	func test_applyAgent_keepsCredentialUntouched() throws {
		// No password, no private key → should leave .agent or any other
		// pre-existing credential alone.
		var host = Host(name: "B", hostname: "h", port: 22, username: "u", credential: .agent)
		try store.addHost(host)
		host = store.hosts.first { $0.id == host.id }!
		try store.applyRemoteCredential(
			decryptedPassword: nil,
			decryptedPassphrase: nil,
			decryptedPrivateKey: nil,
			managedKeyPath: nil,
			for: host.id
		)
		XCTAssertEqual(store.hosts.first { $0.id == host.id }!.credential, .agent)
	}
}
