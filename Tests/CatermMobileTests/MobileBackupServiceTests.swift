import XCTest
import BackupArchive
import BackupService
import KeychainStore
import ManagedKeyStore
import SessionStore
import SnippetSyncClient
import SSHCommandBuilder
@testable import CatermMobile

private actor BackupCommitGate {
	private var isBlocked = false
	private var entryContinuation: CheckedContinuation<Void, Never>?
	private var releaseContinuation: CheckedContinuation<Void, Never>?

	func block() async {
		isBlocked = true
		entryContinuation?.resume()
		entryContinuation = nil
		await withCheckedContinuation { continuation in
			releaseContinuation = continuation
		}
	}

	func waitUntilBlocked() async {
		guard !isBlocked else { return }
		await withCheckedContinuation { continuation in
			entryContinuation = continuation
		}
	}

	func release() {
		releaseContinuation?.resume()
		releaseContinuation = nil
	}

	func blocked() -> Bool { isBlocked }
}

private actor BackupPersistenceGate {
	private var entryContinuation: CheckedContinuation<Void, Never>?
	private var releaseContinuation: CheckedContinuation<Void, Never>?
	private var isReleased = false

	func block() async {
		guard !isReleased else { return }
		await withCheckedContinuation { continuation in
			entryContinuation = continuation
		}
		guard !isReleased else { return }
		await withCheckedContinuation { continuation in
			releaseContinuation = continuation
		}
	}

	func waitUntilBlocked() async {
		while entryContinuation == nil {
			await Task.yield()
		}
		entryContinuation?.resume()
		entryContinuation = nil
	}

	func release() {
		isReleased = true
		releaseContinuation?.resume()
		releaseContinuation = nil
	}
}

private final class FailingBackupCredentialStore: MobileCredentialStoring {
	enum Failure: Error {
		case deleteRejected
	}

	var values: [String: String] = [:]
	var failingDeleteAccounts: Set<String> = []

	func set(account: String, secret: String) throws {
		values[account] = secret
	}

	func get(
		account: String,
		interaction _: KeychainReadInteraction
	) throws -> String {
		guard let value = values[account] else { throw KeychainError.notFound }
		return value
	}

	func delete(account: String) throws {
		guard !failingDeleteAccounts.contains(account) else {
			throw Failure.deleteRejected
		}
		guard values.removeValue(forKey: account) != nil else {
			throw KeychainError.notFound
		}
	}
}

@MainActor
final class MobileBackupServiceTests: XCTestCase {
	private var keychain: KeychainStore!
	private var managedKeys: ManagedKeyStore!
	private var keysRoot: URL!

	override func setUp() async throws {
		try await super.setUp()
		keychain = KeychainStore(
			service: "com.caterm.test.mobile-backup.\(UUID())", accessGroup: nil)
		keysRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent("mobile-keys-\(UUID())", isDirectory: true)
		managedKeys = ManagedKeyStore(rootURL: keysRoot)
	}

	override func tearDown() async throws {
		try? keychain?.deleteAll(prefix: "")
		try? FileManager.default.removeItem(at: keysRoot)
		try await super.tearDown()
	}

	private func date(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

	func test_export_includesKeychainSecrets() throws {
		let host = Host(name: "web", hostname: "h", port: 22, username: "u",
		                credential: .password)
		try keychain.set(account: MobileCredentialPlan.passwordAccount(host.id),
		                 secret: "pw")

		let payload = MobileBackupService.makePayload(
			hosts: [host], snippets: [], includeSecrets: true, keychain: keychain)
		XCTAssertEqual(payload.hosts[0].password, "pw")

		let bare = MobileBackupService.makePayload(
			hosts: [host], snippets: [], includeSecrets: false, keychain: keychain)
		XCTAssertNil(bare.hosts[0].password)
	}

	func test_roundTrip_macFormat_addAppliesSecretsToMobileStores() async throws {
		let archiveId = UUID()
		let payload = BackupPayload(
			exportedAt: date(1),
			hosts: [BackupHost(
				id: archiveId, serverId: "foreign", name: "db", hostname: "d",
				port: 22, username: "u", credentialKind: "keyFile",
				hasPassphrase: true, createdAt: date(0), updatedAt: date(1),
				jumpHostId: nil, forwards: [], icon: nil,
				password: nil, passphrase: "pp", privateKey: Data("PEM".utf8)
			)],
			snippets: [BackupSnippet(id: UUID(), name: "ls", content: "ls",
			                         placeholders: nil, createdAt: date(0),
			                         updatedAt: date(1))]
		)
		// Full envelope round trip — proves cross-platform file compatibility.
		let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
		let sealed = try BackupArchive.seal(
			payload: payload.encoded(), passphrase: "pw123456",
			kdf: ScryptParameters(name: "scrypt", n: 1 << 14, r: 8, p: 1, salt: salt))
		let decoded = try BackupPayload.decode(
			try BackupArchive.open(sealed, passphrase: "pw123456"))

		let plan = MobileBackupService.plan(
			payload: decoded, hosts: [], snippets: [], keychain: keychain)
		XCTAssertEqual(plan.hosts.map(\.kind), [.add])

		let result = try await MobileBackupService.apply(
			plan: plan, hosts: [], snippets: [],
			keychain: keychain, managedKeys: managedKeys)

		XCTAssertEqual(result.summary.hostsAdded, 1)
		XCTAssertEqual(result.summary.snippetsAdded, 1)
		let imported = result.hosts[0]
		XCTAssertNil(imported.serverId)
		XCTAssertEqual(imported.credential,
		               .keyFile(keyPath: managedKeys.path(hostId: archiveId).path,
		                        hasPassphrase: true))
		XCTAssertEqual(try managedKeys.read(hostId: archiveId), Data("PEM".utf8))
		XCTAssertEqual(
			try keychain.get(account: MobileCredentialPlan.keyPassphraseAccount(archiveId)),
			"pp")
	}

	func test_apply_neverDeletes_andLWWSkipsOlderArchive() async throws {
		var local = Host(name: "keep", hostname: "k", port: 22, username: "u",
		                 credential: .password)
		local.updatedAt = date(100)
		try keychain.set(account: MobileCredentialPlan.passwordAccount(local.id),
		                 secret: "x")
		let payload = BackupPayload(exportedAt: date(1), hosts: [
			BackupHost(id: local.id, serverId: nil, name: "stale", hostname: "k",
			           port: 22, username: "u", credentialKind: "password",
			           hasPassphrase: false, createdAt: date(0), updatedAt: date(50),
			           jumpHostId: nil, forwards: [], icon: nil)
		])
		let plan = MobileBackupService.plan(
			payload: payload, hosts: [local], snippets: [], keychain: keychain)
		XCTAssertEqual(plan.hosts.map(\.kind), [.skipLocalNewer])

		let result = try await MobileBackupService.apply(
			plan: plan, hosts: [local], snippets: [],
			keychain: keychain, managedKeys: managedKeys)
		XCTAssertEqual(result.hosts.count, 1)
		XCTAssertEqual(result.hosts[0].name, "keep")
	}

	func test_apply_rewritesJumpChain() async throws {
		let bastionId = UUID()
		let targetId = UUID()
		let payload = BackupPayload(exportedAt: date(1), hosts: [
			BackupHost(id: bastionId, serverId: nil, name: "bastion", hostname: "b",
			           port: 22, username: "u", credentialKind: "password",
			           hasPassphrase: false, createdAt: date(0), updatedAt: date(1),
			           jumpHostId: nil, forwards: [], icon: nil),
			BackupHost(id: targetId, serverId: nil, name: "target", hostname: "t",
			           port: 22, username: "u", credentialKind: "password",
			           hasPassphrase: false, createdAt: date(0), updatedAt: date(1),
			           jumpHostId: bastionId, forwards: [], icon: nil),
		])
		let plan = MobileBackupService.plan(
			payload: payload, hosts: [], snippets: [], keychain: keychain)
		let result = try await MobileBackupService.apply(
			plan: plan, hosts: [], snippets: [],
			keychain: keychain, managedKeys: managedKeys)

		let target = result.hosts.first { $0.id == targetId }!
		XCTAssertEqual(target.jumpHostId, bastionId)
	}

	func test_accountChangeDuringImportRollsBackAllCredentialMaterial() async throws {
		let hostsURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("mobile-backup-hosts-\(UUID()).json")
		defer { try? FileManager.default.removeItem(at: hostsURL) }
		let store = MobileHostStore(
			fileURL: hostsURL,
			managedKeyStore: managedKeys
		)
		let gate = BackupCommitGate()
		let coordinator = MobileBackupImportCoordinator(
			hostStore: store,
			keychain: keychain,
			managedKeys: managedKeys,
			beforeCommit: { await gate.block() }
		)
		let archiveID = UUID()
		let payload = BackupPayload(
			exportedAt: date(2),
			hosts: [BackupHost(
				id: archiveID,
				serverId: "account-a-server",
				name: "account-a",
				hostname: "account-a.example.com",
				port: 22,
				username: "deploy",
				credentialKind: "keyFile",
				hasPassphrase: true,
				createdAt: date(1),
				updatedAt: date(2),
				jumpHostId: nil,
				forwards: [],
				icon: nil,
				password: "account-a-password",
				passphrase: "account-a-passphrase",
				privateKey: Data("ACCOUNT-A-KEY".utf8)
			)]
		)
		let importTask = Task { @MainActor in
			do {
				_ = try await coordinator.apply(
					payload: payload,
					snippets: []
				)
				return false
			} catch {
				return true
			}
		}

		await gate.waitUntilBlocked()
		do {
			try await store.upsert(Host(
				name: "concurrent-account-a",
				hostname: "concurrent.example.com",
				port: 22,
				username: "deploy",
				credential: .agent
			))
			XCTFail("Expected exclusive import to reject a concurrent upsert")
		} catch {
			XCTAssertEqual(
				error as? MobileHostStore.StoreError,
				.accountTransitionInProgress
			)
		}
		do {
			try await store.delete(id: archiveID)
			XCTFail("Expected exclusive import to reject a concurrent deletion")
		} catch {
			XCTAssertEqual(
				error as? MobileHostStore.StoreError,
				.accountTransitionInProgress
			)
		}
		let resetTask = Task { @MainActor in
			try await store.resetForAccountChange()
		}
		await waitUntil { store.isAccountTransitionInProgress }
		await gate.release()

		let importWasRejected = await importTask.value
		XCTAssertTrue(importWasRejected)
		try await resetTask.value
		try store.finishAccountTransition()
		XCTAssertTrue(store.hosts.isEmpty)
		XCTAssertTrue(try HostPersistence.load(from: hostsURL).isEmpty)
		XCTAssertThrowsError(try keychain.get(
			account: MobileCredentialPlan.passwordAccount(archiveID)
		))
		XCTAssertThrowsError(try keychain.get(
			account: MobileCredentialPlan.keyPassphraseAccount(archiveID)
		))
		XCTAssertNil(try managedKeys.read(hostId: archiveID))
	}

	func test_importWaitsForInFlightWriteAndUsesCanonicalHostSnapshot() async throws {
		let hostsURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("mobile-backup-race-\(UUID()).json")
		defer { try? FileManager.default.removeItem(at: hostsURL) }
		let persistenceGate = BackupPersistenceGate()
		let persistence = MobileHostPersistence(
			hostsURL: hostsURL,
			hosts: [],
			beforeMutation: { await persistenceGate.block() }
		)
		let store = MobileHostStore(
			fileURL: hostsURL,
			managedKeyStore: managedKeys,
			persistence: persistence
		)
		let importGate = BackupCommitGate()
		let coordinator = MobileBackupImportCoordinator(
			hostStore: store,
			keychain: keychain,
			managedKeys: managedKeys,
			beforeCommit: { await importGate.block() }
		)
		let directHost = Host(
			name: "direct-write",
			hostname: "direct.example.com",
			port: 22,
			username: "deploy",
			credential: .agent
		)
		let archiveID = UUID()
		let payload = BackupPayload(
			exportedAt: date(2),
			hosts: [BackupHost(
				id: archiveID,
				serverId: nil,
				name: "backup-write",
				hostname: "backup.example.com",
				port: 22,
				username: "deploy",
				credentialKind: "password",
				hasPassphrase: false,
				createdAt: date(1),
				updatedAt: date(2),
				jumpHostId: nil,
				forwards: [],
				icon: nil
			)]
		)
		let directWrite = Task { @MainActor in
			try await store.add(directHost)
		}

		await persistenceGate.waitUntilBlocked()
		let importTask = Task { @MainActor in
			try await coordinator.apply(
				payload: payload,
				snippets: []
			)
		}
		for _ in 0..<20 { await Task.yield() }
		let importReachedCommit = await importGate.blocked()
		XCTAssertFalse(importReachedCommit)

		await persistenceGate.release()
		try await directWrite.value
		await importGate.waitUntilBlocked()
		await importGate.release()
		_ = try await importTask.value

		XCTAssertEqual(Set(store.hosts.map(\.id)), [directHost.id, archiveID])
		XCTAssertEqual(
			Set(try HostPersistence.load(from: hostsURL).map(\.id)),
			[directHost.id, archiveID]
		)
	}

	func test_importReplansConcurrentSameIDAddWithoutDuplicate() async throws {
		let hostsURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("mobile-backup-same-id-\(UUID()).json")
		defer { try? FileManager.default.removeItem(at: hostsURL) }
		let persistenceGate = BackupPersistenceGate()
		let persistence = MobileHostPersistence(
			hostsURL: hostsURL,
			hosts: [],
			beforeMutation: { await persistenceGate.block() }
		)
		let store = MobileHostStore(
			fileURL: hostsURL,
			managedKeyStore: managedKeys,
			persistence: persistence
		)
		let coordinator = MobileBackupImportCoordinator(
			hostStore: store,
			keychain: keychain,
			managedKeys: managedKeys
		)
		let sharedID = UUID()
		let directHost = Host(
			id: sharedID,
			name: "direct",
			hostname: "direct.example.com",
			port: 22,
			username: "deploy",
			credential: .agent,
			createdAt: date(1),
			updatedAt: date(1)
		)
		let payload = BackupPayload(
			exportedAt: date(2),
			hosts: [BackupHost(
				id: sharedID,
				serverId: nil,
				name: "archive",
				hostname: "archive.example.com",
				port: 22,
				username: "deploy",
				credentialKind: "agent",
				hasPassphrase: false,
				createdAt: date(1),
				updatedAt: date(2),
				jumpHostId: nil,
				forwards: [],
				icon: nil
			)]
		)
		let preview = MobileBackupService.plan(
			payload: payload,
			hosts: [],
			snippets: [],
			keychain: keychain
		)
		XCTAssertEqual(preview.hosts.first?.kind, .add)

		let directWrite = Task { @MainActor in
			try await store.add(directHost)
		}
		await persistenceGate.waitUntilBlocked()
		let importTask = Task { @MainActor in
			try await coordinator.apply(payload: payload, snippets: [])
		}
		for _ in 0..<20 { await Task.yield() }
		await persistenceGate.release()
		try await directWrite.value
		_ = try await importTask.value

		XCTAssertEqual(store.hosts.count, 1)
		XCTAssertEqual(store.hosts.first?.id, sharedID)
		XCTAssertEqual(store.hosts.first?.name, "archive")
		let persisted = try HostPersistence.load(from: hostsURL)
		XCTAssertEqual(persisted.count, 1)
		XCTAssertEqual(persisted.first?.id, sharedID)
	}

	func test_importReplansAfterConcurrentNewerLocalUpdate() async throws {
		let hostsURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("mobile-backup-newer-local-\(UUID()).json")
		defer { try? FileManager.default.removeItem(at: hostsURL) }
		let sharedID = UUID()
		let original = Host(
			id: sharedID,
			name: "original",
			hostname: "original.example.com",
			port: 22,
			username: "deploy",
			credential: .agent,
			createdAt: date(1),
			updatedAt: date(1)
		)
		try HostPersistence.save([original], to: hostsURL)
		let persistenceGate = BackupPersistenceGate()
		let persistence = MobileHostPersistence(
			hostsURL: hostsURL,
			hosts: [original],
			beforeMutation: { await persistenceGate.block() }
		)
		let store = MobileHostStore(
			fileURL: hostsURL,
			managedKeyStore: managedKeys,
			persistence: persistence
		)
		let coordinator = MobileBackupImportCoordinator(
			hostStore: store,
			keychain: keychain,
			managedKeys: managedKeys
		)
		let payload = BackupPayload(
			exportedAt: date(2),
			hosts: [BackupHost(
				id: sharedID,
				serverId: nil,
				name: "archive",
				hostname: "archive.example.com",
				port: 22,
				username: "deploy",
				credentialKind: "agent",
				hasPassphrase: false,
				createdAt: date(1),
				updatedAt: date(2),
				jumpHostId: nil,
				forwards: [],
				icon: nil
			)]
		)
		let preview = MobileBackupService.plan(
			payload: payload,
			hosts: [original],
			snippets: [],
			keychain: keychain
		)
		XCTAssertEqual(preview.hosts.first?.kind, .update)
		var newer = original
		newer.name = "local-newer"
		newer.hostname = "local-newer.example.com"
		newer.updatedAt = date(3)

		let directWrite = Task { @MainActor in
			try await store.update(newer)
		}
		await persistenceGate.waitUntilBlocked()
		let importTask = Task { @MainActor in
			try await coordinator.apply(payload: payload, snippets: [])
		}
		for _ in 0..<20 { await Task.yield() }
		await persistenceGate.release()
		try await directWrite.value
		let result = try await importTask.value

		XCTAssertEqual(result.summary.hostsSkipped, 1)
		XCTAssertEqual(store.hosts.count, 1)
		XCTAssertEqual(store.hosts.first?.name, "local-newer")
		XCTAssertEqual(store.hosts.first?.updatedAt, date(3))
		let persisted = try HostPersistence.load(from: hostsURL)
		XCTAssertEqual(persisted.first?.name, "local-newer")
		XCTAssertEqual(persisted.first?.updatedAt, date(3))
	}

	func test_rollbackContinuesAfterOneCredentialItemFails() async throws {
		enum CommitFailure: Error { case rejected }
		let credentials = FailingBackupCredentialStore()
		let archiveID = UUID()
		let passwordAccount = MobileCredentialPlan.passwordAccount(archiveID)
		let passphraseAccount = MobileCredentialPlan.keyPassphraseAccount(archiveID)
		credentials.failingDeleteAccounts = [passwordAccount]
		let payload = BackupPayload(
			exportedAt: date(2),
			hosts: [BackupHost(
				id: archiveID,
				serverId: nil,
				name: "rollback",
				hostname: "rollback.example.com",
				port: 22,
				username: "deploy",
				credentialKind: "keyFile",
				hasPassphrase: true,
				createdAt: date(1),
				updatedAt: date(2),
				jumpHostId: nil,
				forwards: [],
				icon: nil,
				password: "password",
				passphrase: "passphrase",
				privateKey: Data("PRIVATE-KEY".utf8)
			)]
		)
		let plan = BackupMergePlanner.plan(
			payload: payload,
			localHosts: [],
			needsCredentialSetup: { _ in true },
			localSnippets: [],
			localSettingsRevision: nil,
			localBookmarks: { _ in [] },
			localKnownHostsLines: []
		)

		do {
			_ = try await MobileBackupService.apply(
				plan: plan,
				hosts: [],
				snippets: [],
				keychain: credentials,
				managedKeys: managedKeys,
				commit: { _ in throw CommitFailure.rejected }
			)
			XCTFail("Expected rollback failure")
		} catch MobileBackupService.ApplyError.rollbackFailed {
			// Expected.
		}

		XCTAssertEqual(credentials.values[passwordAccount], "password")
		XCTAssertNil(credentials.values[passphraseAccount])
		XCTAssertNil(try managedKeys.read(hostId: archiveID))
	}

	private func waitUntil(
		_ predicate: @MainActor () -> Bool
	) async {
		for _ in 0..<100 where !predicate() {
			await Task.yield()
		}
	}
}
