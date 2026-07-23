import CredentialIdentityStore
import KeychainStore
import ManagedKeyStore
import SSHCommandBuilder
import SSHCredentialContract
@testable import SessionStore
import XCTest

@MainActor
final class CredentialIdentityMigrationTests: XCTestCase {
	func testConfirmMigrationAtomicallyDeletesHostOwnedCredential()
		async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(
			"identity-migration-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: root) }
		let hostsURL = root.appendingPathComponent("hosts.json")
		let managedKeys = ManagedKeyStore(
			rootURL: root.appendingPathComponent("keys", isDirectory: true)
		)
		let secrets = MigrationMemorySecretStore()
		let materialStore = SessionCredentialMaterialStore(
			secrets: secrets,
			managedKeyStore: managedKeys
		)
		let keychain = KeychainStore(
			service: "com.caterm.test.identity-migration",
			accessGroup: nil
		)
		let store = SessionStore(
			askpassPath: "/x",
			knownHostsCaterm: "/A",
			knownHostsUser: "/B",
			accessGroup: nil,
			hostsURL: hostsURL,
			keychain: keychain,
			managedKeyStore: managedKeys,
			credentialMaterialStore: materialStore
		)
		var host = SSHHost(
			name: "Production",
			hostname: "prod.example",
			username: "deploy",
			credential: .password,
			credentialIdentity: HostCredentialIdentityReference(
				identityID: UUID(),
				migrationState: .reversible
			)
		)
		try store.addHost(host)
		try await store.setHostCredentialMaterial(
			secrets: HostSecrets(password: Data("legacy".utf8)),
			credentialSource: .password,
			for: host.id
		)
		XCTAssertFalse(secrets.isEmpty)

		host = try XCTUnwrap(store.hosts.first)
		host.credentialIdentity?.migrationState = .confirmed
		try await store.confirmCredentialIdentityMigration(host)

		XCTAssertTrue(secrets.isEmpty)
		XCTAssertEqual(
			store.hosts.first?.credentialIdentity?.migrationState,
			.confirmed
		)
		XCTAssertFalse(
			try XCTUnwrap(store.hosts.first).credentialMaterialDirty
		)
	}

	func testConfirmMigrationCannotCommitAfterIdentityDeletion()
		async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(
			"identity-migration-race-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: root) }
		let identities = CredentialIdentityStore(
			fileURL: root.appendingPathComponent("identities.json")
		)
		let identity = CredentialIdentity(
			name: "Shared",
			username: "deploy",
			source: .password(materialID: CredentialMaterialID())
		)
		try await identities.upsert(identity)
		let secrets = MigrationMemorySecretStore()
		let managedKeys = ManagedKeyStore(
			rootURL: root.appendingPathComponent("keys", isDirectory: true)
		)
		let store = SessionStore(
			askpassPath: "/x",
			knownHostsCaterm: "/A",
			knownHostsUser: "/B",
			accessGroup: nil,
			hostsURL: root.appendingPathComponent("hosts.json"),
			keychain: KeychainStore(
				service: "com.caterm.test.identity-migration-race",
				accessGroup: nil
			),
			managedKeyStore: managedKeys,
			credentialMaterialStore: SessionCredentialMaterialStore(
				secrets: secrets,
				managedKeyStore: managedKeys
			),
			credentialIdentityStore: identities
		)
		let host = SSHHost(
			name: "Production",
			hostname: "prod.example",
			username: "deploy",
			credential: .password
		)
		try store.addHost(host)
		try await store.setHostCredentialMaterial(
			secrets: HostSecrets(password: Data("legacy".utf8)),
			credentialSource: .password,
			for: host.id
		)
		var assigned = try XCTUnwrap(store.hosts.first)
		assigned.credentialIdentity = .init(
			identityID: identity.id,
			migrationState: .confirmed
		)
		let blocker = MigrationDeletionBlocker()
		let deletion = Task { @MainActor in
			try await identities.withTransaction {
				try await identities.withDeletionReservation(id: identity.id) {
					await blocker.block()
					try await identities.applyRemoteTombstone(id: identity.id)
				}
			}
		}
		await blocker.waitUntilBlocked()
		let confirmation = Task { @MainActor in
			try await store.confirmCredentialIdentityMigration(assigned)
		}
		for _ in 0..<20 { await Task.yield() }
		XCTAssertNil(store.hosts.first?.credentialIdentity)
		XCTAssertFalse(secrets.isEmpty)

		await blocker.release()
		try await deletion.value
		do {
			try await confirmation.value
			XCTFail("Expected the deleted identity assignment to fail")
		} catch {
			XCTAssertEqual(
				error as? CredentialIdentityStoreError,
				.identityNotFound(identity.id)
			)
		}
		XCTAssertNil(store.hosts.first?.credentialIdentity)
		XCTAssertFalse(secrets.isEmpty)
	}
}

private actor MigrationDeletionBlocker {
	private var blocked = false
	private var waiters: [CheckedContinuation<Void, Never>] = []
	private var releaseContinuation: CheckedContinuation<Void, Never>?

	func block() async {
		blocked = true
		waiters.forEach { $0.resume() }
		waiters.removeAll()
		await withCheckedContinuation {
			releaseContinuation = $0
		}
	}

	func waitUntilBlocked() async {
		guard !blocked else { return }
		await withCheckedContinuation { waiters.append($0) }
	}

	func release() {
		releaseContinuation?.resume()
		releaseContinuation = nil
	}
}

private final class MigrationMemorySecretStore: CredentialSecretStoring,
	@unchecked Sendable {
	private let lock = NSLock()
	private var values: [String: String] = [:]

	var isEmpty: Bool {
		lock.withLock { values.isEmpty }
	}

	func get(
		account: String,
		interaction: KeychainReadInteraction
	) throws -> String {
		try lock.withLock {
			guard let value = values[account] else {
				throw KeychainError.notFound
			}
			return value
		}
	}

	func set(account: String, secret: String) throws {
		lock.withLock { values[account] = secret }
	}

	func delete(account: String) throws {
		lock.withLock { values[account] = nil }
	}

	func deleteAll(prefix: String) throws {
		lock.withLock {
			for account in values.keys where account.hasPrefix(prefix) {
				values[account] = nil
			}
		}
	}
}
