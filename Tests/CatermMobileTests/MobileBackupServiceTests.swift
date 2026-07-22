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
		let plan = MobileBackupService.plan(
			payload: payload,
			hosts: [],
			snippets: [],
			keychain: keychain
		)
		let importTask = Task { @MainActor in
			do {
				_ = try await coordinator.apply(
					plan: plan,
					hosts: [],
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

	private func waitUntil(
		_ predicate: @MainActor () -> Bool
	) async {
		for _ in 0..<100 where !predicate() {
			await Task.yield()
		}
	}
}
