import XCTest
import BackupArchive
import Foundation
import KeychainStore
import ManagedKeyStore
import SettingsStore
import SnippetStore
import SnippetSyncClient
import SSHCommandBuilder
@testable import BackupService
@testable import SessionStore

@MainActor
final class BackupServiceTests: XCTestCase {
	private var root: URL!
	private var keychain: KeychainStore!
	private var store: SessionStore!
	private var managedKeys: ManagedKeyStore!
	private var snippetStore: SnippetStore!
	private var settingsStore: SettingsStore!
	private var bookmarkStore: RemoteBookmarkStore!

	override func setUp() async throws {
		try await super.setUp()
		root = FileManager.default.temporaryDirectory
			.appendingPathComponent("backup-service-\(UUID())", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		keychain = KeychainStore(
			service: "com.caterm.test.backup-service.\(UUID())", accessGroup: nil)
		managedKeys = ManagedKeyStore(rootURL: root.appendingPathComponent("keys"))
		store = SessionStore(
			askpassPath: "/x",
			knownHostsCaterm: root.appendingPathComponent("known_hosts").path,
			knownHostsUser: "/B", accessGroup: nil,
			hostsURL: root.appendingPathComponent("hosts.json"),
			keychain: keychain,
			managedKeyStore: managedKeys
		)
		snippetStore = SnippetStore(directory: root.appendingPathComponent("Snippets"))
		try snippetStore.load()
		settingsStore = SettingsStore(
			settings: CatermSettings(revision: "0-local", global: PartialSettings()),
			path: root.appendingPathComponent("settings.plist")
		)
		bookmarkStore = RemoteBookmarkStore(
			directory: root.appendingPathComponent("RemoteBookmarks"))
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: root)
		try? keychain?.deleteAll(prefix: "")
		try await super.tearDown()
	}

	private func date(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

	private func makePayload(hosts: [BackupHost] = [], snippets: [BackupSnippet] = [],
	                         settings: BackupSettings? = nil,
	                         bookmarks: [BackupBookmark] = [],
	                         knownHosts: [String] = []) -> BackupPayload {
		BackupPayload(exportedAt: date(2_000_000), hosts: hosts, snippets: snippets,
		              settings: settings, bookmarks: bookmarks, knownHosts: knownHosts)
	}

	private func computePlan(_ payload: BackupPayload) async -> BackupMergePlan {
		let localHosts = store.hosts
		var hostsNeedingCredentials: Set<UUID> = []
		for host in localHosts {
			if await store.needsCredentialSetup(host) {
				hostsNeedingCredentials.insert(host.id)
			}
		}
		return BackupMergePlanner.plan(
			payload: payload,
			localHosts: localHosts,
			needsCredentialSetup: { hostsNeedingCredentials.contains($0.id) },
			localSnippets: snippetStore.snippets,
			localSettingsRevision: settingsStore.settings.revision,
			localBookmarks: { self.bookmarkStore.bookmarks(for: $0) },
			localKnownHostsLines: []
		)
	}

	private func applyPlan(_ plan: BackupMergePlan, settings: BackupSettings? = nil) async throws -> BackupImportSummary {
		try await BackupImporter.apply(
			plan: plan, sessionStore: store,
			snippetStore: snippetStore, settingsStore: settingsStore,
			archiveSettings: settings, bookmarkStore: bookmarkStore
		)
	}

	private func waitForGlobalCredentialQueue(
		_ expectedCount: Int,
		materialStore: SessionCredentialMaterialStore
	) async {
		for _ in 0 ..< 1_000 {
			if await materialStore.waitingGlobalTransactionCount() == expectedCount {
				return
			}
			await Task.yield()
		}
		XCTFail("timed out waiting for global credential transaction queue")
	}

	private func archiveHost(
		id: UUID = UUID(), serverId: String? = nil, name: String = "web",
		hostname: String = "example.com", username: String = "root",
		updatedAt: Date, credentialKind: String = "password",
		hasPassphrase: Bool = false, jumpHostId: UUID? = nil,
		password: String? = nil, passphrase: String? = nil, privateKey: Data? = nil
	) -> BackupHost {
		BackupHost(id: id, serverId: serverId, name: name, hostname: hostname,
		           port: 22, username: username, credentialKind: credentialKind,
		           hasPassphrase: hasPassphrase, createdAt: date(1_000),
		           updatedAt: updatedAt, jumpHostId: jumpHostId, forwards: [],
		           icon: nil, password: password, passphrase: passphrase,
		           privateKey: privateKey)
	}

	// MARK: Exporter

	func test_export_roundTripsHostWithSecretsAndManagedKey() async throws {
		let host = Host(name: "web", hostname: "h", port: 22, username: "u",
		                credential: .password)
		try store.addHost(host)
		try await store.setHostCredentialMaterial(
			secrets: HostSecrets(password: Data("pw".utf8)),
			credentialSource: .password, for: host.id)

		let keyHost = Host(name: "db", hostname: "d", port: 22, username: "u",
		                   credential: .password)
		try store.addHost(keyHost)
		try await store.setHostCredentialMaterial(
			secrets: HostSecrets(passphrase: Data("pp".utf8), privateKeyBytes: Data("KEY".utf8)),
			credentialSource: .keyFile(keyPath: "", hasPassphrase: true),
			for: keyHost.id)

		let payload = try await BackupExporter.makePayload(
			includeSecrets: true, sessionStore: store,
			snippets: [], settings: settingsStore.settings,
			bookmarks: { _ in [] })

		let web = payload.hosts.first { $0.id == host.id }!
		XCTAssertEqual(web.credentialKind, "password")
		XCTAssertEqual(web.password, "pw")
		let db = payload.hosts.first { $0.id == keyHost.id }!
		XCTAssertEqual(db.credentialKind, "keyFile")
		XCTAssertEqual(db.passphrase, "pp")
		XCTAssertEqual(db.privateKey, Data("KEY".utf8))
	}

	func test_export_withoutSecrets_carriesNoSecretMaterial() async throws {
		let host = Host(name: "web", hostname: "h", port: 22, username: "u",
		                credential: .password)
		try store.addHost(host)
		try await store.setHostCredentialMaterial(
			secrets: HostSecrets(password: Data("pw".utf8)),
			credentialSource: .password, for: host.id)

		let payload = try await BackupExporter.makePayload(
			includeSecrets: false, sessionStore: store,
			snippets: [], settings: nil, bookmarks: { _ in [] })

		XCTAssertNil(payload.hosts[0].password)
		XCTAssertNil(payload.hosts[0].privateKey)
	}

	func test_export_retriesWhenHostGraphChangesDuringCredentialRead() async throws {
		var target = Host(
			name: "target",
			hostname: "target.example",
			username: "root",
			credential: .agent
		)
		try store.addHost(target)
		let provisional = try await store.credentialMaterialStore.applyLocal(
			HostSecrets(),
			source: .agent,
			for: target.id
		)
		let export = Task { @MainActor in
			try await BackupExporter.makePayload(
				includeSecrets: true,
				sessionStore: store,
				snippets: [],
				settings: nil,
				bookmarks: { self.bookmarkStore.bookmarks(for: $0) }
			)
		}
		await waitForGlobalCredentialQueue(
			1,
			materialStore: store.credentialMaterialStore
		)

		let jump = Host(
			name: "jump",
			hostname: "jump.example",
			username: "root",
			credential: .agent
		)
		try store.addHost(jump)
		target.jumpHostId = jump.id
		try store.updateHost(target)
		_ = bookmarkStore.add(
			RemoteBookmark(label: "logs", path: "/var/log"),
			for: jump.id
		)
		await store.credentialMaterialStore.finalizeLocalCommit(provisional)

		let payload = try await export.value
		let hostIDs = Set(payload.hosts.map(\.id))
		XCTAssertEqual(hostIDs, Set([target.id, jump.id]))
		let exportedTarget = try XCTUnwrap(
			payload.hosts.first { $0.id == target.id }
		)
		XCTAssertEqual(exportedTarget.jumpHostId, jump.id)
		XCTAssertEqual(payload.bookmarks.map(\.hostId), [jump.id])
		XCTAssertTrue(
			Set(payload.bookmarks.map(\.hostId)).isSubset(of: hostIDs)
		)
	}

	func test_export_doesNotMixManagedKeysAcrossAccountReset() async throws {
		let keyA = Data("KEY-A".utf8)
		let keyB = Data("KEY-B".utf8)
		let isolatedManagedKeys = ManagedKeyStore(
			rootURL: root.appendingPathComponent("account-reset-keys")
		)
		let materialStore = SessionCredentialMaterialStore(
			secrets: InMemoryBackupCredentialSecretStore(),
			managedKeyStore: isolatedManagedKeys
		)
		let isolatedStore = SessionStore(
			askpassPath: "/x",
			knownHostsCaterm: root.appendingPathComponent(
				"account-reset-known-hosts"
			).path,
			knownHostsUser: "/B",
			accessGroup: nil,
			hostsURL: root.appendingPathComponent("account-reset-hosts.json"),
			keychain: keychain,
			managedKeyStore: isolatedManagedKeys,
			credentialMaterialStore: materialStore
		)
		let hostA = Host(
			name: "A",
			hostname: "a.example",
			username: "root",
			credential: .password
		)
		let hostB = Host(
			name: "B",
			hostname: "b.example",
			username: "root",
			credential: .password
		)
		try isolatedStore.addHost(hostA)
		try isolatedStore.addHost(hostB)
		try await isolatedStore.setHostCredentialMaterial(
			secrets: HostSecrets(privateKeyBytes: keyA),
			credentialSource: .keyFile(keyPath: "", hasPassphrase: false),
			for: hostA.id
		)
		try await isolatedStore.setHostCredentialMaterial(
			secrets: HostSecrets(privateKeyBytes: keyB),
			credentialSource: .keyFile(keyPath: "", hasPassphrase: false),
			for: hostB.id
		)
		guard case let .keyFile(path, hasPassphrase) = isolatedStore.hosts
			.first(where: { $0.id == hostA.id })?.credential else {
			return XCTFail("expected managed key source")
		}
		let provisional = try await materialStore.applyLocal(
			HostSecrets(),
			source: .keyFile(path: path, hasPassphrase: hasPassphrase),
			for: hostA.id
		)

		let export = Task { @MainActor in
			try await BackupExporter.makePayload(
				includeSecrets: true,
				sessionStore: isolatedStore,
				snippets: [],
				settings: nil,
				bookmarks: { _ in [] }
			)
		}
		await waitForGlobalCredentialQueue(1, materialStore: materialStore)
		let reset = Task {
			try await materialStore.resetManagedKeysForAccountChange()
		}
		await waitForGlobalCredentialQueue(2, materialStore: materialStore)
		await materialStore.finalizeLocalCommit(provisional)

		let payload = try await export.value
		try await reset.value

		XCTAssertEqual(
			payload.hosts.first(where: { $0.id == hostA.id })?.privateKey,
			keyA
		)
		XCTAssertEqual(
			payload.hosts.first(where: { $0.id == hostB.id })?.privateKey,
			keyB
		)
		XCTAssertNil(try isolatedManagedKeys.read(hostId: hostA.id))
		XCTAssertNil(try isolatedManagedKeys.read(hostId: hostB.id))
	}

	// MARK: Planner

	func test_plan_matchesByUUID_thenServerId_elseAdds() async throws {
		var localById = Host(name: "a", hostname: "h", port: 22, username: "u",
		                     credential: .password)
		localById.updatedAt = date(100)
		try store.addHost(localById)
		var localBySid = Host(name: "b", hostname: "h2", port: 22, username: "u",
		                      credential: .password)
		localBySid.serverId = "srv-9"
		localBySid.updatedAt = date(100)
		try store.addHost(localBySid)

		let payload = makePayload(hosts: [
			archiveHost(id: localById.id, updatedAt: date(200)),          // newer → update
			archiveHost(serverId: "srv-9", updatedAt: date(50)),          // older → skip
			archiveHost(name: "new", updatedAt: date(10)),                // no match → add
		])
		let plan = await computePlan(payload)

		XCTAssertEqual(plan.hosts.map(\.kind), [.update, .skipLocalNewer, .add])
		XCTAssertEqual(plan.hostIdMapping[payload.hosts[1].id], localBySid.id)
		XCTAssertEqual(plan.hostIdMapping[payload.hosts[2].id], payload.hosts[2].id)
	}

	func test_plan_hostUUIDMatchWinsOverConflictingServerIDMatch() async throws {
		var localByID = Host(
			name: "by-id",
			hostname: "id.example",
			username: "root",
			credential: .password
		)
		localByID.serverId = "server-a"
		localByID.updatedAt = date(100)
		var localByServerID = Host(
			name: "by-server-id",
			hostname: "server.example",
			username: "root",
			credential: .password
		)
		localByServerID.serverId = "server-b"
		localByServerID.updatedAt = date(100)
		try store.addHost(localByID)
		try store.addHost(localByServerID)
		let archive = archiveHost(
			id: localByID.id,
			serverId: "server-b",
			updatedAt: date(50)
		)

		let plan = await computePlan(makePayload(hosts: [archive]))

		XCTAssertEqual(plan.hosts.first?.localHostId, localByID.id)
		XCTAssertEqual(plan.hostIdMapping[archive.id], localByID.id)
	}

	func test_plan_sameEndpointWithoutIdentityMatchAddsHost() async throws {
		var local = Host(
			name: "local",
			hostname: "shared.example",
			username: "root",
			credential: .password
		)
		local.updatedAt = date(100)
		try store.addHost(local)
		let archive = archiveHost(
			name: "archive",
			hostname: "shared.example",
			updatedAt: date(200)
		)

		let plan = await computePlan(makePayload(hosts: [archive]))

		XCTAssertEqual(plan.hosts.first?.kind, .add)
	}

	func test_plan_equalHostTimestampKeepsLocalMetadata() async throws {
		var local = Host(
			name: "local",
			hostname: "local.example",
			username: "root",
			credential: .password
		)
		local.updatedAt = date(100)
		try store.addHost(local)
		let archive = archiveHost(
			id: local.id,
			name: "archive",
			hostname: "archive.example",
			updatedAt: date(100)
		)

		let plan = await computePlan(makePayload(hosts: [archive]))

		XCTAssertEqual(plan.hosts.first?.kind, .skipLocalNewer)
	}

	func test_plan_backupSnippetUsesTimestampInsteadOfSyncRevision() async throws {
		let id = UUID()
		let local = Snippet(
			id: id,
			name: "local",
			content: "local-content",
			createdAt: date(0),
			updatedAt: date(100),
			revision: 999,
			metadataUpdatedAt: date(500)
		)
		_ = try snippetStore.applyRemote(local)
		let archive = BackupSnippet(
			id: id,
			name: "archive",
			content: "archive-content",
			placeholders: nil,
			createdAt: date(0),
			updatedAt: date(200)
		)

		let plan = await computePlan(makePayload(snippets: [archive]))

		XCTAssertEqual(plan.snippets.first?.kind, .update)
	}

	func test_plan_equalBackupSnippetTimestampKeepsLocal() async throws {
		let id = UUID()
		let local = Snippet(
			id: id,
			name: "local",
			content: "local-content",
			createdAt: date(0),
			updatedAt: date(100)
		)
		_ = try snippetStore.applyRemote(local)
		let archive = BackupSnippet(
			id: id,
			name: "archive",
			content: "archive-content",
			placeholders: nil,
			createdAt: date(0),
			updatedAt: date(100)
		)

		let plan = await computePlan(makePayload(snippets: [archive]))

		XCTAssertEqual(plan.snippets.first?.kind, .skipLocalNewer)
	}

	func test_plan_localNewerButMissingCredential_getsCredentialsOnly() async throws {
		var local = Host(name: "a", hostname: "h", port: 22, username: "u",
		                 credential: .password) // no keychain item → needsCredentialSetup
		local.updatedAt = date(300)
		try store.addHost(local)

		let payload = makePayload(hosts: [
			archiveHost(id: local.id, updatedAt: date(100), password: "pw"),
		])
		let plan = await computePlan(payload)
		XCTAssertEqual(plan.hosts.map(\.kind), [.credentialsOnly])
	}

	func test_plan_settingsLWWByRevision() async {
		let newer = await computePlan(makePayload(settings: BackupSettings(
			revision: "9-archive", global: PartialSettings(), hostOverrides: [:])))
		XCTAssertEqual(
			newer.settings,
			.apply)
		let older = await computePlan(makePayload(settings: BackupSettings(
			revision: "0-", global: PartialSettings(), hostOverrides: [:])))
		XCTAssertEqual(
			older.settings,
			.skipLocalNewer)
		let empty = await computePlan(makePayload())
		XCTAssertEqual(empty.settings, .none)
	}

	// MARK: Importer end-to-end

	func test_apply_add_stripsServerId_preservesTimestamps_importsSecrets() async throws {
		let a = archiveHost(serverId: "foreign-srv", updatedAt: date(500),
		                    credentialKind: "keyFile", hasPassphrase: true,
		                    passphrase: "pp", privateKey: Data("PEM".utf8))
		let plan = await computePlan(makePayload(hosts: [a]))
		let summary = try await applyPlan(plan)

		XCTAssertEqual(summary.hostsAdded, 1)
		let local = store.hosts.first { $0.id == a.id }!
		XCTAssertNil(local.serverId, "foreign serverId must not leak into local state")
		XCTAssertEqual(local.updatedAt, date(500))
		XCTAssertEqual(local.credential,
		               .keyFile(keyPath: managedKeys.path(hostId: a.id).path,
		                        hasPassphrase: true))
		XCTAssertEqual(try managedKeys.read(hostId: a.id), Data("PEM".utf8))
		XCTAssertEqual(try keychain.get(account: "\(a.id.uuidString).keyPassphrase"), "pp")
		XCTAssertTrue(local.credentialMaterialDirty)
	}

	func test_apply_update_appliesMetadata_keepsLocalServerIdAndCredential() async throws {
		var local = Host(name: "old", hostname: "old.example", port: 22,
		                 username: "u", credential: .password)
		local.serverId = "srv-1"
		local.updatedAt = date(100)
		try store.addHost(local)
		try store.setHostSecret("localpw", hostId: local.id, kind: .password)

		let a = archiveHost(id: local.id, name: "renamed", hostname: "new.example",
		                    updatedAt: date(200))
		let plan = await computePlan(makePayload(hosts: [a]))
		let summary = try await applyPlan(plan)

		XCTAssertEqual(summary.hostsUpdated, 1)
		let updated = store.hosts.first { $0.id == local.id }!
		XCTAssertEqual(updated.name, "renamed")
		XCTAssertEqual(updated.hostname, "new.example")
		XCTAssertEqual(updated.serverId, "srv-1", "local sync identity preserved")
		XCTAssertEqual(try keychain.get(account: "\(local.id.uuidString).password"), "localpw")
	}

	func test_apply_credentialsOnly_leavesMetadataAlone() async throws {
		var local = Host(name: "keep-name", hostname: "keep.example", port: 22,
		                 username: "u", credential: .password)
		local.updatedAt = date(300)
		try store.addHost(local)

		let a = archiveHost(id: local.id, name: "archive-name",
		                    updatedAt: date(100), password: "importedpw")
		let plan = await computePlan(makePayload(hosts: [a]))
		let summary = try await applyPlan(plan)

		XCTAssertEqual(summary.hostsCredentialsOnly, 1)
		let after = store.hosts.first { $0.id == local.id }!
		XCTAssertEqual(after.name, "keep-name", "metadata must not regress to older archive")
		XCTAssertEqual(try keychain.get(account: "\(local.id.uuidString).password"),
		               "importedpw")
	}

	func test_apply_rewritesJumpChainToLocalIdentities() async throws {
		// Local bastion matched by serverId (different local UUID).
		var bastion = Host(name: "bastion", hostname: "b", port: 22, username: "u",
		                   credential: .password)
		bastion.serverId = "srv-bastion"
		bastion.updatedAt = date(100)
		try store.addHost(bastion)
		try store.setHostSecret("x", hostId: bastion.id, kind: .password)

		let archiveBastionId = UUID() // exporting device's UUID for the same bastion
		let target = archiveHost(name: "target", updatedAt: date(10),
		                         jumpHostId: archiveBastionId, password: "pw")
		let archiveBastion = archiveHost(id: archiveBastionId, serverId: "srv-bastion",
		                                 name: "bastion", updatedAt: date(50))
		let plan = await computePlan(makePayload(hosts: [archiveBastion, target]))
		_ = try await applyPlan(plan)

		let imported = store.hosts.first { $0.id == target.id }!
		XCTAssertEqual(imported.jumpHostId, bastion.id,
		               "chain must point at the LOCAL bastion UUID")
		XCTAssertEqual(imported.jumpHostServerId, "srv-bastion")
	}

	func test_apply_snippets_addAndLWWUpdate() async throws {
		try snippetStore.upsert(Snippet(id: UUID(), name: "keep", content: "newer",
		                                createdAt: date(0), updatedAt: date(0)))
		var localNewer = snippetStore.snippets[0]

		let archiveOlder = BackupSnippet(id: localNewer.id, name: "keep",
		                                 content: "older", placeholders: nil,
		                                 createdAt: date(0), updatedAt: date(0))
		let archiveNew = BackupSnippet(id: UUID(), name: "fresh", content: "echo hi",
		                               placeholders: ["x"], createdAt: date(1),
		                               updatedAt: date(1))
		// upsert stamped updatedAt=now, so archiveOlder(t=0) loses LWW.
		let plan = await computePlan(makePayload(snippets: [archiveOlder, archiveNew]))
		let summary = try await applyPlan(plan)

		XCTAssertEqual(summary.snippetsAdded, 1)
		XCTAssertEqual(summary.snippetsSkipped, 1)
		localNewer = snippetStore.snippets.first { $0.id == localNewer.id }!
		XCTAssertEqual(localNewer.content, "newer")
		XCTAssertEqual(snippetStore.snippets.count, 2)
	}

	func test_apply_settings_unionsAndRemapsHostOverrides() async throws {
		// Local override for a local-only host must survive the import.
		var local = Host(name: "local-only", hostname: "l", port: 22, username: "u",
		                 credential: .password)
		local.updatedAt = date(100)
		try store.addHost(local)
		var current = settingsStore.settings
		current.hostOverrides[HostId(local.id.uuidString)] = PartialSettings()
		try settingsStore.save(current)

		// Archive override keyed by the exporting device's UUID for a host
		// we match by serverId.
		var matched = Host(name: "matched", hostname: "m", port: 22, username: "u",
		                   credential: .password)
		matched.serverId = "srv-m"
		matched.updatedAt = date(100)
		try store.addHost(matched)
		try store.setHostSecret("x", hostId: matched.id, kind: .password)
		let archiveHostId = UUID()
		let payload = makePayload(
			hosts: [archiveHost(id: archiveHostId, serverId: "srv-m",
			                    name: "matched", updatedAt: date(50))],
			settings: BackupSettings(revision: "z-archive", global: PartialSettings(),
			                         hostOverrides: [archiveHostId.uuidString: PartialSettings()])
		)
		let plan = await computePlan(payload)
		XCTAssertEqual(plan.settings, .apply)
		let summary = try await applyPlan(plan, settings: payload.settings)

		XCTAssertTrue(summary.settingsApplied)
		let overrides = settingsStore.settings.hostOverrides
		XCTAssertNotNil(overrides[HostId(local.id.uuidString)],
		                "local-only override must survive (imports never delete)")
		XCTAssertNotNil(overrides[HostId(matched.id.uuidString)],
		                "archive override must be remapped to the local host id")
		XCTAssertNil(overrides[HostId(archiveHostId.uuidString)])
		XCTAssertNotEqual(settingsStore.settings.revision, "z-archive",
		                  "import is a local edit — fresh revision so settings sync pushes")
	}

	func test_apply_bookmarks_dedupedByPath_andKnownHostsAppended() async throws {
		var local = Host(name: "a", hostname: "h", port: 22, username: "u",
		                 credential: .password)
		local.updatedAt = date(100)
		try store.addHost(local)
		try store.setHostSecret("x", hostId: local.id, kind: .password)
		_ = bookmarkStore.add(RemoteBookmark(label: "www", path: "/var/www"),
		                      for: local.id)

		let payload = makePayload(
			hosts: [archiveHost(id: local.id, updatedAt: date(50))],
			bookmarks: [
				BackupBookmark(id: UUID(), hostId: local.id, label: "dup",
				               path: "/var/www/", createdAt: date(1)),   // same normalized path
				BackupBookmark(id: UUID(), hostId: local.id, label: "logs",
				               path: "/var/log", createdAt: date(2)),
			],
			knownHosts: ["example.com ssh-ed25519 AAAA"]
		)
		let plan = await computePlan(payload)
		let summary = try await applyPlan(plan)

		XCTAssertEqual(summary.bookmarksAdded, 1)
		XCTAssertEqual(bookmarkStore.bookmarks(for: local.id).count, 2)
		XCTAssertEqual(summary.knownHostsAppended, 1)
		let written = try String(contentsOfFile: store.knownHostsCaterm, encoding: .utf8)
		XCTAssertTrue(written.contains("example.com ssh-ed25519 AAAA"))
	}

	func test_apply_neverDeletesLocalEntities() async throws {
		var local = Host(name: "survivor", hostname: "s", port: 22, username: "u",
		                 credential: .password)
		local.updatedAt = date(100)
		try store.addHost(local)
		try snippetStore.upsert(Snippet(id: UUID(), name: "s", content: "c",
		                                createdAt: date(0), updatedAt: date(0)))

		let plan = await computePlan(makePayload())
		_ = try await applyPlan(plan) // empty archive

		XCTAssertEqual(store.hosts.count, 1)
		XCTAssertEqual(snippetStore.snippets.count, 1)
	}
}

private final class InMemoryBackupCredentialSecretStore:
	CredentialSecretStoring, @unchecked Sendable {
	private let lock = NSLock()
	private var values: [String: String] = [:]

	func get(account: String) throws -> String {
		lock.lock()
		defer { lock.unlock() }
		guard let value = values[account] else {
			throw KeychainError.notFound
		}
		return value
	}

	func set(account: String, secret: String) {
		lock.lock()
		values[account] = secret
		lock.unlock()
	}

	func delete(account: String) throws {
		lock.lock()
		defer { lock.unlock() }
		guard values.removeValue(forKey: account) != nil else {
			throw KeychainError.notFound
		}
	}

	func deleteAll(prefix: String) {
		lock.lock()
		values = values.filter { !$0.key.hasPrefix(prefix) }
		lock.unlock()
	}
}
