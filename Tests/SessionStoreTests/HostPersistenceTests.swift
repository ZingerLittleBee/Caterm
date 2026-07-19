import XCTest
import ManagedKeyStore
@testable import KeychainStore
@testable import SessionStore
@testable import SSHCommandBuilder

final class HostPersistenceTests: XCTestCase {
	var tmpURL: URL!

	override func setUp() {
		tmpURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-test-\(UUID()).json")
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: tmpURL)
	}

	func testRoundtripWithAllThreeCredentialKinds() throws {
		let hosts: [SSHHost] = [
			SSHHost(name: "p", hostname: "h1", port: 22, username: "u", credential: .password),
			SSHHost(name: "k", hostname: "h2", port: 2222, username: "u",
			        credential: .keyFile(keyPath: "/x/y", hasPassphrase: true)),
			SSHHost(name: "a", hostname: "h3", port: 22, username: "u", credential: .agent),
		]
		try HostPersistence.save(hosts, to: tmpURL)
		let read = try HostPersistence.load(from: tmpURL)
		XCTAssertEqual(read.count, 3)
		XCTAssertEqual(read[0].credential, .password)
		XCTAssertEqual(read[1].credential, .keyFile(keyPath: "/x/y", hasPassphrase: true))
		XCTAssertEqual(read[2].credential, .agent)
	}

	func testLoadMissingFileReturnsEmpty() throws {
		let result = try HostPersistence.load(from: tmpURL)
		XCTAssertTrue(result.isEmpty)
	}

	func testFilePermissionsAre0600() throws {
		try HostPersistence.save([], to: tmpURL)
		let attrs = try FileManager.default.attributesOfItem(atPath: tmpURL.path)
		let perm = attrs[.posixPermissions] as? Int
		XCTAssertEqual(perm, 0o600)
	}

	func testSaveOverwritesExisting() throws {
		try HostPersistence.save([
			SSHHost(name: "first", hostname: "h", port: 22, username: "u", credential: .agent),
		], to: tmpURL)
		try HostPersistence.save([
			SSHHost(name: "second", hostname: "h", port: 22, username: "u", credential: .agent),
		], to: tmpURL)
		let read = try HostPersistence.load(from: tmpURL)
		XCTAssertEqual(read.count, 1)
		XCTAssertEqual(read.first?.name, "second")
	}

	@MainActor
	func testSessionStoreCRUDPersists() async throws {
		let kc = KeychainStore(service: "com.caterm.test.\(UUID())", accessGroup: nil)
		let managedKeys = ManagedKeyStore(
			rootURL: tmpURL.deletingLastPathComponent()
				.appendingPathComponent("host-persistence-keys-\(UUID())")
		)
		let materialStore = SessionCredentialMaterialStore(
			secrets: InMemoryCredentialSecretStore(),
			managedKeyStore: managedKeys
		)
		let store = SessionStore(
			askpassPath: "/x", knownHostsCaterm: "/A", knownHostsUser: "/B",
			accessGroup: nil, hostsURL: tmpURL, keychain: kc,
			managedKeyStore: managedKeys,
			credentialMaterialStore: materialStore
		)
		let host = SSHHost(name: "x", hostname: "h", port: 22, username: "u", credential: .agent)
		try store.addHost(host)

		// Re-load fresh store, verify host present
		let store2 = SessionStore(
			askpassPath: "/x", knownHostsCaterm: "/A", knownHostsUser: "/B",
			accessGroup: nil, hostsURL: tmpURL, keychain: kc,
			managedKeyStore: managedKeys,
			credentialMaterialStore: materialStore
		)
		XCTAssertEqual(store2.hosts.count, 1)
		XCTAssertEqual(store2.hosts.first?.name, "x")

		try await store2.deleteHost(id: host.id)
		let store3 = SessionStore(
			askpassPath: "/x", knownHostsCaterm: "/A", knownHostsUser: "/B",
			accessGroup: nil, hostsURL: tmpURL, keychain: kc,
			managedKeyStore: managedKeys
		)
		XCTAssertEqual(store3.hosts.count, 0)
	}
}
