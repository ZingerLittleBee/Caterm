import XCTest
import BackupArchive
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
		store = SessionStore(
			askpassPath: "/x",
			knownHostsCaterm: root.appendingPathComponent("known_hosts").path,
			knownHostsUser: "/B", accessGroup: nil,
			hostsURL: root.appendingPathComponent("hosts.json"),
			keychain: keychain
		)
		managedKeys = ManagedKeyStore(rootURL: root.appendingPathComponent("keys"))
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

	private func computePlan(_ payload: BackupPayload) -> BackupMergePlan {
		BackupMergePlanner.plan(
			payload: payload,
			localHosts: store.hosts,
			needsCredentialSetup: { self.store.needsCredentialSetup($0) },
			localSnippets: snippetStore.snippets,
			localSettingsRevision: settingsStore.settings.revision,
			localBookmarks: { self.bookmarkStore.bookmarks(for: $0) },
			localKnownHostsLines: []
		)
	}

	private func applyPlan(_ plan: BackupMergePlan, settings: BackupSettings? = nil) async throws -> BackupImportSummary {
		try await BackupImporter.apply(
			plan: plan, sessionStore: store, managedKeys: managedKeys,
			snippetStore: snippetStore, settingsStore: settingsStore,
			archiveSettings: settings, bookmarkStore: bookmarkStore
		)
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
		try store.setHostCredentialMaterial(
			secrets: HostSecrets(password: Data("pw".utf8)),
			credentialSource: .password, for: host.id)

		let keyHost = Host(name: "db", hostname: "d", port: 22, username: "u",
		                   credential: .password)
		try store.addHost(keyHost)
		let managed = try await managedKeys.write(hostId: keyHost.id, bytes: Data("KEY".utf8))
		try store.setHostCredentialMaterial(
			secrets: HostSecrets(passphrase: Data("pp".utf8), privateKeyBytes: Data("KEY".utf8)),
			credentialSource: .keyFile(keyPath: managed.path, hasPassphrase: true),
			for: keyHost.id)

		let payload = try BackupExporter.makePayload(
			includeSecrets: true, sessionStore: store, managedKeys: managedKeys,
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
		try store.setHostCredentialMaterial(
			secrets: HostSecrets(password: Data("pw".utf8)),
			credentialSource: .password, for: host.id)

		let payload = try BackupExporter.makePayload(
			includeSecrets: false, sessionStore: store, managedKeys: managedKeys,
			snippets: [], settings: nil, bookmarks: { _ in [] })

		XCTAssertNil(payload.hosts[0].password)
		XCTAssertNil(payload.hosts[0].privateKey)
	}

	// MARK: Planner

	func test_plan_matchesByUUID_thenServerId_elseAdds() throws {
		var localById = Host(name: "a", hostname: "h", port: 22, username: "u",
		                     credential: .password)
		localById.updatedAt = date(100)
		try store.addHost(localById)
		var localBySid = Host(name: "b", hostname: "h2", port: 22, username: "u",
		                      credential: .password)
		localBySid.serverId = "srv-9"
		localBySid.updatedAt = date(100)
		try store.addHost(localBySid)
		try store.setHostSecret("x", hostId: localById.id, kind: .password)
		try store.setHostSecret("x", hostId: localBySid.id, kind: .password)

		let payload = makePayload(hosts: [
			archiveHost(id: localById.id, updatedAt: date(200)),          // newer → update
			archiveHost(serverId: "srv-9", updatedAt: date(50)),          // older → skip
			archiveHost(name: "new", updatedAt: date(10)),                // no match → add
		])
		let plan = computePlan(payload)

		XCTAssertEqual(plan.hosts.map(\.kind), [.update, .skipLocalNewer, .add])
		XCTAssertEqual(plan.hostIdMapping[payload.hosts[1].id], localBySid.id)
		XCTAssertEqual(plan.hostIdMapping[payload.hosts[2].id], payload.hosts[2].id)
	}

	func test_plan_localNewerButMissingCredential_getsCredentialsOnly() throws {
		var local = Host(name: "a", hostname: "h", port: 22, username: "u",
		                 credential: .password) // no keychain item → needsCredentialSetup
		local.updatedAt = date(300)
		try store.addHost(local)

		let payload = makePayload(hosts: [
			archiveHost(id: local.id, updatedAt: date(100), password: "pw"),
		])
		XCTAssertEqual(computePlan(payload).hosts.map(\.kind), [.credentialsOnly])
	}

	func test_plan_settingsLWWByRevision() {
		XCTAssertEqual(
			computePlan(makePayload(settings: BackupSettings(
				revision: "9-archive", global: PartialSettings(), hostOverrides: [:]))).settings,
			.apply)
		XCTAssertEqual(
			computePlan(makePayload(settings: BackupSettings(
				revision: "0-", global: PartialSettings(), hostOverrides: [:]))).settings,
			.skipLocalNewer)
		XCTAssertEqual(computePlan(makePayload()).settings, .none)
	}

	// MARK: Importer end-to-end

	func test_apply_add_stripsServerId_preservesTimestamps_importsSecrets() async throws {
		let a = archiveHost(serverId: "foreign-srv", updatedAt: date(500),
		                    credentialKind: "keyFile", hasPassphrase: true,
		                    passphrase: "pp", privateKey: Data("PEM".utf8))
		let plan = computePlan(makePayload(hosts: [a]))
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
		let summary = try await applyPlan(computePlan(makePayload(hosts: [a])))

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
		let summary = try await applyPlan(computePlan(makePayload(hosts: [a])))

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
		let plan = computePlan(makePayload(hosts: [archiveBastion, target]))
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
		let plan = computePlan(makePayload(snippets: [archiveOlder, archiveNew]))
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
		let plan = computePlan(payload)
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
		let plan = computePlan(payload)
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

		_ = try await applyPlan(computePlan(makePayload())) // empty archive

		XCTAssertEqual(store.hosts.count, 1)
		XCTAssertEqual(snippetStore.snippets.count, 1)
	}
}
