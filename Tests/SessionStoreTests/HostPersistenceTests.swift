import XCTest
import ManagedKeyStore
@testable import KeychainStore
@testable import SessionStore
@testable import SSHCommandBuilder

final class HostPersistenceTests: XCTestCase {
	var tmpURL: URL!
	var deletionOutboxURL: URL {
		tmpURL.deletingPathExtension().appendingPathExtension("deletions.json")
	}

	override func setUp() {
		tmpURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-test-\(UUID()).json")
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: tmpURL)
		try? FileManager.default.removeItem(at: deletionOutboxURL)
	}

	func testRoundtripWithAllThreeCredentialKinds() async throws {
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

	func testLoadMissingFileReturnsEmpty() async throws {
		let result = try HostPersistence.load(from: tmpURL)
		XCTAssertTrue(result.isEmpty)
	}

	func testFilePermissionsAre0600() async throws {
		try HostPersistence.save([], to: tmpURL)
		let attrs = try FileManager.default.attributesOfItem(atPath: tmpURL.path)
		let perm = attrs[.posixPermissions] as? Int
		XCTAssertEqual(perm, 0o600)
	}

	func testHostDeletionOutboxPersistsWithPrivatePermissions() async throws {
		var outbox = HostDeletionOutbox(hostsURL: tmpURL)
		try outbox.insert("srv-1")

		let restored = HostDeletionOutbox(hostsURL: tmpURL)
		XCTAssertEqual(try restored.pendingIDs(), ["srv-1"])
		let attributes = try FileManager.default.attributesOfItem(
			atPath: deletionOutboxURL.path
		)
		XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

		var clearing = restored
		try clearing.remove("srv-1")
		XCTAssertTrue(try HostDeletionOutbox(hostsURL: tmpURL).pendingIDs().isEmpty)
	}

	func testCorruptHostDeletionOutboxFailsClosed() async throws {
		try Data("not-json".utf8).write(to: deletionOutboxURL)
		var outbox = HostDeletionOutbox(hostsURL: tmpURL)

		XCTAssertThrowsError(try outbox.pendingIDs())
		XCTAssertThrowsError(try outbox.insert("srv-1"))
	}

	func testSaveOverwritesExisting() async throws {
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
		try await store.addHost(host)

		// Re-load fresh store, verify host present
		let store2 = SessionStore(
			askpassPath: "/x", knownHostsCaterm: "/A", knownHostsUser: "/B",
			accessGroup: nil, hostsURL: tmpURL, keychain: kc,
			managedKeyStore: managedKeys,
			credentialMaterialStore: materialStore
		)
		try await store2.prepareHostRepository()
		XCTAssertEqual(store2.hosts.count, 1)
		XCTAssertEqual(store2.hosts.first?.name, "x")

		try await store2.deleteHost(id: host.id)
		let store3 = SessionStore(
			askpassPath: "/x", knownHostsCaterm: "/A", knownHostsUser: "/B",
			accessGroup: nil, hostsURL: tmpURL, keychain: kc,
			managedKeyStore: managedKeys
		)
		try await store3.prepareHostRepository()
		XCTAssertEqual(store3.hosts.count, 0)
	}

	@MainActor
	func testPendingRemoteDeletionPersistsAcrossSessionStoreRestart() async throws {
		let keyStore = ManagedKeyStore(
			rootURL: tmpURL.deletingLastPathComponent()
				.appendingPathComponent("host-deletion-keys-\(UUID())")
		)
		let materialStore = SessionCredentialMaterialStore(
			secrets: InMemoryCredentialSecretStore(),
			managedKeyStore: keyStore
		)
		let keychain = KeychainStore(
			service: "com.caterm.test.\(UUID())", accessGroup: nil
		)
		let original = SessionStore(
			askpassPath: "/x", knownHostsCaterm: "/A", knownHostsUser: "/B",
			accessGroup: nil, hostsURL: tmpURL, keychain: keychain,
			managedKeyStore: keyStore, credentialMaterialStore: materialStore
		)
		var host = SSHHost(
			name: "alpha", hostname: "x", username: "u", credential: .agent
		)
		host.serverId = "srv-1"
		try await original.addHost(host)

		try await original.deleteHost(id: host.id)
		let restored = SessionStore(
			askpassPath: "/x", knownHostsCaterm: "/A", knownHostsUser: "/B",
			accessGroup: nil, hostsURL: tmpURL, keychain: keychain,
			managedKeyStore: keyStore, credentialMaterialStore: materialStore
		)
		try await restored.prepareHostRepository()

		XCTAssertTrue(restored.hosts.isEmpty)
		let pendingIDs = try await restored.pendingRemoteHostDeletionIDs()
		XCTAssertEqual(pendingIDs, ["srv-1"])
	}
}
