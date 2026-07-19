import XCTest
import KeychainStore
import ManagedKeyStore
import SSHCommandBuilder
@testable import HostKeyProvisioning
@testable import SessionStore

@MainActor
final class HostKeyProvisionerTests: XCTestCase {
	private var hostsURL: URL!
	private var keysRoot: URL!
	private var externalDir: URL!
	private var keychain: KeychainStore!
	private var store: SessionStore!
	private var managedKeys: ManagedKeyStore!

	override func setUp() async throws {
		try await super.setUp()
		let tmp = FileManager.default.temporaryDirectory
		hostsURL = tmp.appendingPathComponent("hosts-\(UUID()).json")
		keysRoot = tmp.appendingPathComponent("keys-\(UUID())", isDirectory: true)
		externalDir = tmp.appendingPathComponent("ssh-\(UUID())", isDirectory: true)
		try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
		keychain = KeychainStore(
			service: "com.caterm.test.host-key-provisioner.\(UUID())",
			accessGroup: nil
		)
		managedKeys = ManagedKeyStore(rootURL: keysRoot)
		store = SessionStore(
			askpassPath: "/x", knownHostsCaterm: "/A",
			knownHostsUser: "/B", accessGroup: nil,
			hostsURL: hostsURL, keychain: keychain,
			managedKeyStore: managedKeys
		)
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: hostsURL)
		try? FileManager.default.removeItem(at: keysRoot)
		try? FileManager.default.removeItem(at: externalDir)
		try? keychain?.deleteAll(prefix: "")
		try await super.tearDown()
	}

	private func addHost(credential: CredentialSource) throws -> SSHHost {
		let host = Host(name: "h", hostname: "example.com", port: 22,
		                username: "u", credential: credential)
		try store.addHost(host)
		return store.hosts.first { $0.id == host.id }!
	}

	private func writeExternalKey(_ bytes: String = "PEM_BYTES") throws -> String {
		let url = externalDir.appendingPathComponent("id_test")
		try Data(bytes.utf8).write(to: url)
		return url.path
	}

	// MARK: keyBytes(from:)

	func test_keyBytes_file_readsBytes() throws {
		let path = try writeExternalKey("FILE_KEY")
		XCTAssertEqual(try HostKeyProvisioner.keyBytes(from: .file(path: path)),
		               Data("FILE_KEY".utf8))
	}

	func test_keyBytes_missingFile_throws() {
		XCTAssertThrowsError(
			try HostKeyProvisioner.keyBytes(from: .file(path: "/nonexistent/id_x"))
		) { error in
			XCTAssertEqual(error as? HostKeyProvisioningError,
			               .unreadableFile(path: "/nonexistent/id_x"))
		}
	}

	func test_keyBytes_pasted_trimsAndAppendsNewline() throws {
		let bytes = try HostKeyProvisioner.keyBytes(
			from: .pasted(content: "  -----BEGIN KEY-----\nabc\n-----END KEY-----\n\n")
		)
		XCTAssertEqual(bytes, Data("-----BEGIN KEY-----\nabc\n-----END KEY-----\n".utf8))
	}

	func test_keyBytes_pastedWhitespaceOnly_throwsEmptyKey() {
		XCTAssertThrowsError(
			try HostKeyProvisioner.keyBytes(from: .pasted(content: "  \n "))
		) { error in
			XCTAssertEqual(error as? HostKeyProvisioningError, .emptyKey)
		}
	}

	// MARK: provision

	func test_provision_pasted_writesManagedKey_andPointsCredentialAtIt() async throws {
		let host = try addHost(credential: .password)
		try await HostKeyProvisioner.provision(
			material: .pasted(content: "PASTED_KEY"),
			hasPassphrase: false, passphrase: nil,
			hostId: host.id, sessionStore: store
		)
		let managedPath = managedKeys.path(hostId: host.id).path
		XCTAssertEqual(try managedKeys.read(hostId: host.id), Data("PASTED_KEY\n".utf8))
		let updated = store.hosts.first { $0.id == host.id }!
		XCTAssertEqual(updated.credential,
		               .keyFile(keyPath: managedPath, hasPassphrase: false))
		XCTAssertTrue(updated.credentialMaterialDirty,
		              "new key material must be flagged for credential sync push")
	}

	func test_provision_withPassphrase_storesPassphraseInKeychain() async throws {
		let host = try addHost(credential: .password)
		let path = try writeExternalKey()
		try await HostKeyProvisioner.provision(
			material: .file(path: path),
			hasPassphrase: true, passphrase: "pp",
			hostId: host.id, sessionStore: store
		)
		XCTAssertEqual(try keychain.get(account: "\(host.id.uuidString).keyPassphrase"), "pp")
		let updated = store.hosts.first { $0.id == host.id }!
		XCTAssertEqual(updated.credential,
		               .keyFile(keyPath: managedKeys.path(hostId: host.id).path,
		                        hasPassphrase: true))
	}

	// MARK: migrateExternalKeyPaths

	func test_migrate_externalPath_copiesBytes_rewritesPath_noDirtyNoUpdatedAtBump() async throws {
		let path = try writeExternalKey("EXTERNAL")
		let host = try addHost(credential: .keyFile(keyPath: path, hasPassphrase: true))
		let updatedAtBefore = host.updatedAt

		let summary = await HostKeyProvisioner.migrateExternalKeyPaths(
			sessionStore: store
		)

		XCTAssertEqual(summary, {
			var s = KeyMigrationSummary(); s.migrated = 1; return s
		}())
		let migrated = store.hosts.first { $0.id == host.id }!
		XCTAssertEqual(migrated.credential,
		               .keyFile(keyPath: managedKeys.path(hostId: host.id).path,
		                        hasPassphrase: true))
		XCTAssertEqual(try managedKeys.read(hostId: host.id), Data("EXTERNAL".utf8))
		XCTAssertFalse(migrated.credentialMaterialDirty,
		               "relocation must not trigger a credential sync push")
		XCTAssertEqual(migrated.updatedAt, updatedAtBefore,
		               "relocation must not look like a metadata edit to host sync")
		// Source file is never deleted.
		XCTAssertTrue(FileManager.default.fileExists(atPath: path))
	}

	func test_migrate_unreadableSource_leavesHostUntouched() async throws {
		let host = try addHost(credential: .keyFile(keyPath: "/nonexistent/id_gone",
		                                            hasPassphrase: false))
		let summary = await HostKeyProvisioner.migrateExternalKeyPaths(
			sessionStore: store
		)
		XCTAssertEqual(summary.skippedUnreadable, 1)
		XCTAssertEqual(summary.migrated, 0)
		let untouched = store.hosts.first { $0.id == host.id }!
		XCTAssertEqual(untouched.credential,
		               .keyFile(keyPath: "/nonexistent/id_gone", hasPassphrase: false))
	}

	func test_migrate_alreadyManaged_isIdempotentSkip() async throws {
		let host = try addHost(credential: .password)
		try await HostKeyProvisioner.provision(
			material: .pasted(content: "K"), hasPassphrase: false, passphrase: nil,
			hostId: host.id, sessionStore: store
		)
		let summary = await HostKeyProvisioner.migrateExternalKeyPaths(
			sessionStore: store
		)
		XCTAssertEqual(summary.alreadyManaged, 1)
		XCTAssertEqual(summary.migrated, 0)
	}

	func test_migrate_passwordHosts_ignored() async throws {
		_ = try addHost(credential: .password)
		let summary = await HostKeyProvisioner.migrateExternalKeyPaths(
			sessionStore: store
		)
		XCTAssertEqual(summary, KeyMigrationSummary())
	}

	func test_migrate_cancelledTask_stopsBeforeReadingHosts() async throws {
		let path = try writeExternalKey("EXTERNAL")
		let host = try addHost(
			credential: .keyFile(keyPath: path, hasPassphrase: false)
		)

		let summary = await Task { @MainActor in
			withUnsafeCurrentTask { task in
				task?.cancel()
			}
			return await HostKeyProvisioner.migrateExternalKeyPaths(
				sessionStore: store
			)
		}.value

		XCTAssertEqual(summary, KeyMigrationSummary())
		let untouched = try XCTUnwrap(store.hosts.first { $0.id == host.id })
		XCTAssertEqual(
			untouched.credential,
			.keyFile(keyPath: path, hasPassphrase: false)
		)
	}
}
