import CatermMobileTerminal
import CloudKitSyncClient
import CredentialSync
import CredentialSyncStore
import CredentialSyncTypes
import Foundation
import KeychainStore
import ManagedKeyStore
import ServerSyncClient
import SessionStore
import SSHCommandBuilder
import SSHCredentialContract
@testable import CatermMobile
import Testing

private final class MobileSyncFixtureClient: IncrementalHostSyncClient,
	@unchecked Sendable {
	private let lock = NSLock()
	private var hosts: [String: RemoteHost] = [:]
	private var blobs: [String: CredentialBlob] = [:]
	private var nextID = 0
	private(set) var resetCount = 0

	func listHosts() async throws -> [RemoteHost] {
		lock.withLock { Array(hosts.values) }
	}

	func createHost(
		_ input: RemoteHostCreateInput
	) async throws -> RemoteHostCreateOutput {
		lock.withLock {
			nextID += 1
			let id = "mobile-server-\(nextID)"
			hosts[id] = RemoteHost(
				id: id,
				name: input.name,
				hostname: input.hostname,
				port: input.port,
				username: input.username,
				authType: input.authType,
				createdAt: input.metadataUpdatedAt,
				updatedAt: input.metadataUpdatedAt,
				jumpHostServerId: input.jumpHostServerId,
				forwards: input.forwards,
				icon: input.icon,
				organization: input.organization
			)
			return RemoteHostCreateOutput(id: id)
		}
	}

	func updateHost(_ input: RemoteHostUpdateInput) async throws {
		lock.withLock {
			guard let old = hosts[input.id] else { return }
			hosts[input.id] = RemoteHost(
				id: old.id,
				name: input.name ?? old.name,
				hostname: input.hostname ?? old.hostname,
				port: input.port ?? old.port,
				username: input.username ?? old.username,
				authType: input.authType ?? old.authType,
				createdAt: old.createdAt,
				updatedAt: input.metadataUpdatedAt ?? old.updatedAt,
				jumpHostServerId: input.jumpHostServerId,
				forwards: input.forwards ?? old.forwards,
				icon: input.icon,
				organization: input.organization ?? old.organization
			)
		}
	}

	func deleteHost(id: String) async throws {
		lock.withLock {
			hosts.removeValue(forKey: id)
			blobs.removeValue(forKey: id)
		}
	}

	func pushHostCredentialBlob(
		serverId: String,
		blob: CredentialBlob
	) async throws -> Int64 {
		lock.withLock {
			blobs[serverId] = blob
		}
		return blob.revision
	}

	func preferredHostSyncMode() async -> HostSyncMode { .forceFull }

	func fetchHostChanges() async throws -> HostChangeBatch {
		try await fetchHostSnapshotAndCheckpoint()
	}

	func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch {
		lock.withLock {
			HostChangeBatch(
				changedHosts: Array(hosts.values),
				deletedHostIDs: [],
				credentialBlobsByServerId: blobs,
				checkpoint: nil,
				tokenExpired: false,
				mode: .forceFull
			)
		}
	}

	func commitHostCheckpoint(_: any HostSyncCheckpoint) async throws {}
	func ensureHostSubscription() async throws {}
	func deleteHostSubscription() async throws {}
	func resetHostSyncState() async {
		lock.withLock { resetCount += 1 }
	}

	func ciphertextSnapshot() -> [CredentialBlob] {
		lock.withLock { Array(blobs.values) }
	}

	func switchToEmptyAccount() {
		lock.withLock {
			hosts = [:]
			blobs = [:]
		}
	}
}

private final class MobileSyncAccountState: @unchecked Sendable {
	private let lock = NSLock()
	private var signedIn = true
	private var identity = "account-a"
	private var priorIdentity: String?

	func isSignedIn() -> Bool { lock.withLock { signedIn } }

	func set(identity: String?, signedIn: Bool) {
		lock.withLock {
			self.identity = identity ?? ""
			self.signedIn = signedIn
		}
	}

	func evaluate() -> AccountChangeOutcome {
		lock.withLock {
			let current = identity.isEmpty ? nil : identity
			defer { priorIdentity = current }
			switch (priorIdentity, current) {
			case (nil, nil): return .unchanged
			case (nil, .some): return .firstObservation
			case let (.some(prior), .some(next)) where prior == next:
				return .unchanged
			case (.some, _): return .identityChanged
			}
		}
	}
}

@Test("Mobile repositories round-trip Host metadata and encrypted credentials")
@MainActor
private func mobileRepositoriesRoundTripMetadataAndCredentials() async throws {
	let fixture = try MobileSyncDeviceFixture()
	defer { fixture.cleanup() }
	let client = MobileSyncFixtureClient()
	let masterA = KeychainSyncMasterKeyStore(
		service: fixture.masterKeyService,
		synchronizable: false
	)
	let generated = try await masterA.generate()
	let masterB = KeychainSyncMasterKeyStore(
		service: fixture.masterKeyService,
		synchronizable: false
	)
	defer { Task { await masterA.remove(keyID: generated.keyID) } }

	let deviceA = fixture.makeDevice(name: "A", masterKey: masterA)
	let jump = SSHHost(
		name: "Bastion",
		hostname: "jump.example.com",
		username: "ops",
		credential: .agent,
		icon: "point.3.connected.trianglepath.dotted",
		organization: HostOrganization(groupPath: ["Production"], tags: ["edge"])
	)
	try deviceA.store.add(jump)
	let target = SSHHost(
		name: "Database",
		hostname: "db.internal",
		port: 2222,
		username: "deploy",
		credential: .keyFile(keyPath: "/placeholder", hasPassphrase: true),
		credentialMaterialDirty: true,
		jumpHostId: jump.id,
		forwards: [PortForward(
			kind: .local,
			bindAddress: "127.0.0.1",
			bindPort: 15432,
			remoteHost: "127.0.0.1",
			remotePort: 5432,
			label: "Postgres"
		)],
		icon: "cylinder.split.1x2",
		organization: HostOrganization(
			groupPath: ["Production", "Databases"],
			tags: ["Primary", "PCI"]
		)
	)
	let keyBytes = Data("fixture-private-key".utf8)
	let targetCommit = try await deviceA.material.applyLocal(
		HostSecrets(
			passphrase: Data("correct horse".utf8),
			privateKeyBytes: keyBytes
		),
		source: .keyFile(path: target.credential.keyPathForTesting, hasPassphrase: true),
		for: target.id
	)
	var storedTarget = target
	if case let .keyFile(path, hasPassphrase) = targetCommit.source {
		storedTarget.credential = .keyFile(
			keyPath: path,
			hasPassphrase: hasPassphrase
		)
	}
	try deviceA.store.add(storedTarget)
	await deviceA.material.finalizeLocalCommit(targetCommit)

	let passwordHost = SSHHost(
		name: "API",
		hostname: "api.example.com",
		username: "release",
		credential: .password,
		credentialMaterialDirty: true,
		organization: HostOrganization(tags: ["deploy"])
	)
	let passwordCommit = try await deviceA.material.applyLocal(
		HostSecrets(password: Data("swordfish".utf8)),
		source: .password,
		for: passwordHost.id
	)
	try deviceA.store.add(passwordHost)
	await deviceA.material.finalizeLocalCommit(passwordCommit)

	_ = try await deviceA.engine(client).synchronize(request: .forceFull)

	let blobs = client.ciphertextSnapshot()
	#expect(blobs.count == 2)
	#expect(blobs.allSatisfy { blob in
		let fields = [
			blob.passwordCiphertext,
			blob.passphraseCiphertext,
			blob.privateKeyCiphertext,
		].compactMap { $0 }
		return fields.allSatisfy {
			$0.range(of: Data("swordfish".utf8)) == nil
				&& $0.range(of: Data("correct horse".utf8)) == nil
				&& $0.range(of: keyBytes) == nil
		}
	})

	let deviceB = fixture.makeDevice(name: "B", masterKey: masterB)
	_ = try await deviceB.engine(client).synchronize(request: .forceFull)

	let pulledTarget = try #require(deviceB.store.hosts.first(where: {
		$0.name == "Database"
	}))
	#expect(pulledTarget.hostname == "db.internal")
	#expect(pulledTarget.port == 2222)
	#expect(pulledTarget.icon == "cylinder.split.1x2")
	#expect(pulledTarget.organization.groupPath == ["Production", "Databases"])
	#expect(pulledTarget.organization.tags == ["Primary", "PCI"])
	#expect(pulledTarget.forwards == storedTarget.forwards)
	#expect(pulledTarget.jumpHostServerId != nil)
	#expect(pulledTarget.jumpHostId != nil)

	let planProvider = MobileAuthenticationPlanProvider(materialStore: deviceB.material)
	let keyPlan = await planProvider.resolve(
		host: pulledTarget,
		credentialSyncState: .enabled
	)
	guard case let .available(plan) = keyPlan,
		case let .privateKey(blob, passphrase)? = plan.attempts.first else {
		Issue.record("Expected a usable private-key authentication plan")
		return
	}
	#expect(blob == keyBytes)
	#expect(passphrase == "correct horse")

	let pulledPassword = try #require(deviceB.store.hosts.first(where: {
		$0.name == "API"
	}))
	let passwordPlan = await planProvider.resolve(
		host: pulledPassword,
		credentialSyncState: .enabled
	)
	guard case let .available(plan) = passwordPlan else {
		Issue.record("Expected a usable password authentication plan")
		return
	}
	#expect(plan.attempts == [.password("swordfish")])
	#expect(plan.missing == nil)
	#expect(try HostPersistence.load(from: deviceB.hostsURL) == deviceB.store.hosts)
}

@Test("Mobile authentication distinguishes pending sync keys and device-only keys")
@MainActor
private func mobileAuthenticationSurfacesUnavailableMaterial() async throws {
	let fixture = try MobileSyncDeviceFixture()
	defer { fixture.cleanup() }
	let master = KeychainSyncMasterKeyStore(
		service: fixture.masterKeyService,
		synchronizable: false
	)
	let device = fixture.makeDevice(name: "unavailable", masterKey: master)
	let provider = MobileAuthenticationPlanProvider(materialStore: device.material)
	let password = SSHHost(
		name: "Pending",
		hostname: "pending.example.com",
		username: "ops",
		credential: .password
	)
	#expect(await provider.resolve(
		host: password,
		credentialSyncState: .waitingForKey(observedKeyID: "key-a")
	) == .unavailable(.syncMasterKeyPending(keyID: "key-a")))

	let key = SSHHost(
		name: "Device Key",
		hostname: "key.example.com",
		username: "ops",
		credential: .keyFile(
			keyPath: fixture.root.appendingPathComponent("missing-key").path,
			hasPassphrase: false
		)
	)
	#expect(await provider.resolve(
		host: key,
		credentialSyncState: .enabled
	) == .unavailable(.deviceBoundPrivateKeyUnavailable))
}

@Test("Mobile account transition clears account A before account B sync")
@MainActor
private func mobileAccountTransitionDoesNotMergeAccounts() async throws {
	let fixture = try MobileSyncDeviceFixture()
	defer { fixture.cleanup() }
	let client = MobileSyncFixtureClient()
	let master = KeychainSyncMasterKeyStore(
		service: fixture.masterKeyService,
		synchronizable: false
	)
	let device = fixture.makeDevice(name: "runtime", masterKey: master)
	let account = MobileSyncAccountState()
	try device.store.add(SSHHost(
		name: "Account A only",
		hostname: "a.example.com",
		username: "a",
		credential: .agent
	))
	let runtime = MobileHostSyncRuntime(
		hostStore: device.store,
		syncEngine: device.engine(client),
		client: client,
		credentialSync: device.preferences,
		isSignedIn: { account.isSignedIn() },
		refreshAccount: {},
		identityBoundary: MobileAccountIdentityBoundary(
			evaluate: { account.evaluate() },
			acknowledge: {}
		),
		debounceInterval: 0
	)
	await runtime.launch()
	account.set(identity: "account-b", signedIn: true)
	client.switchToEmptyAccount()
	await runtime.accountDidChange()

	#expect(runtime.hostStore === device.store)
	#expect(!device.store.hosts.contains { $0.name == "Account A only" })
	#expect(runtime.state != MobileHostSyncState.signedOut)
}

@Test("Mobile boot composition shares one Host store with the sync runtime")
@MainActor
private func mobileBootCompositionUsesSharedRuntime() throws {
	let fixture = try MobileSyncDeviceFixture()
	defer { fixture.cleanup() }
	let client = MobileSyncFixtureClient()
	let master = KeychainSyncMasterKeyStore(
		service: fixture.masterKeyService,
		synchronizable: false
	)
	let device = fixture.makeDevice(name: "composition", masterKey: master)
	let runtime = MobileHostSyncRuntime(
		hostStore: device.store,
		syncEngine: device.engine(client),
		client: client,
		credentialSync: device.preferences,
		isSignedIn: { false },
		refreshAccount: {}
	)
	let writer = MobileCredentialWriter(keychain: KeychainStore(
		service: "com.caterm.test.mobile-writer.\(UUID().uuidString)",
		accessGroup: nil
	))
	let composition = MobileAppComposition(
		hostStore: device.store,
		credentialWriter: writer,
		syncRuntime: runtime,
		terminalSessionFactory: MobileTerminalSessionFactory { _ in
			throw MobileCredentialUnavailableReason.credentialReadFailed
		}
	)

	#expect(composition.hostStore === device.store)
	#expect(composition.syncRuntime === runtime)
	#expect(composition.syncRuntime.hostStore === composition.hostStore)
}

@Test("Offline mobile composition never constructs CloudKit")
@MainActor
private func offlineMobileCompositionAvoidsCloudKitWithoutEntitlement() throws {
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(
		"mobile-offline-composition-\(UUID().uuidString)",
		isDirectory: true
	)
	defer { try? FileManager.default.removeItem(at: root) }
	var constructedCloudKit = false
	let composition = MobileAppComposition.live(
		hostsURL: root.appendingPathComponent("hosts.json"),
		applicationSupportURL: root,
		cloudKitEnabled: false,
		containerFactory: {
			constructedCloudKit = true
			fatalError("CloudKit must not be constructed in offline mode")
		}
	)

	#expect(!constructedCloudKit)
	#expect(composition.syncRuntime.hostStore === composition.hostStore)
}

@Test("Known Hosts remain device-local after a Host sync")
@MainActor
private func knownHostsRemainDeviceLocalAfterSync() async throws {
	let fixture = try MobileSyncDeviceFixture()
	defer { fixture.cleanup() }
	let client = MobileSyncFixtureClient()
	let master = KeychainSyncMasterKeyStore(
		service: fixture.masterKeyService,
		synchronizable: false
	)
	let deviceA = fixture.makeDevice(name: "known-a", masterKey: master)
	let deviceB = fixture.makeDevice(name: "known-b", masterKey: master)
	let knownA = MobileKnownHostsStore(
		fileURL: fixture.root.appendingPathComponent("known-a.json")
	)
	let knownB = MobileKnownHostsStore(
		fileURL: fixture.root.appendingPathComponent("known-b.json")
	)
	try knownA.trust(endpoint: "server.example.com:22", fingerprint: "SHA256:A")
	try knownB.trust(endpoint: "server.example.com:22", fingerprint: "SHA256:B")
	try deviceA.store.add(SSHHost(
		name: "Server",
		hostname: "server.example.com",
		username: "ops",
		credential: .agent
	))

	_ = try await deviceA.engine(client).synchronize(request: .forceFull)
	_ = try await deviceB.engine(client).synchronize(request: .forceFull)

	#expect(knownA.evaluate(
		endpoint: "server.example.com:22",
		fingerprint: "SHA256:A"
	) == .trusted)
	#expect(knownB.evaluate(
		endpoint: "server.example.com:22",
		fingerprint: "SHA256:B"
	) == .trusted)
	#expect(knownB.evaluate(
		endpoint: "server.example.com:22",
		fingerprint: "SHA256:A"
	) == .mismatch)
}

private struct MobileSyncDeviceFixture {
	let root: URL
	let masterKeyService = "com.caterm.test.mobile-master.\(UUID().uuidString)"

	init() throws {
		root = FileManager.default.temporaryDirectory.appendingPathComponent(
			"caterm-mobile-sync-\(UUID().uuidString)",
			isDirectory: true
		)
		try FileManager.default.createDirectory(
			at: root,
			withIntermediateDirectories: true
		)
	}

	@MainActor
	func makeDevice(
		name: String,
		masterKey: KeychainSyncMasterKeyStore
	) -> MobileSyncDevice {
		let directory = root.appendingPathComponent(name, isDirectory: true)
		let hostsURL = directory.appendingPathComponent("hosts.json")
		let managed = ManagedKeyStore(
			rootURL: directory.appendingPathComponent("keys", isDirectory: true)
		)
		let material = SessionCredentialMaterialStore(
			keychainService: SSHCredentialContract.keychainService,
			keychainAccessGroup: nil,
			managedKeyStore: managed
		)
		let store = MobileHostStore(
			fileURL: hostsURL,
			managedKeyStore: managed,
			credentialMaterialStore: material
		)
		let defaults = UserDefaults(
			suiteName: "MobileSyncDevice.\(UUID().uuidString)"
		) ?? .standard
		let preferences = CredentialSyncPreferencesStore(defaults: defaults)
		preferences.mutate { $0.state = .enabled }
		return MobileSyncDevice(
			store: store,
			material: material,
			masterKey: masterKey,
			preferences: preferences,
			hostsURL: hostsURL
		)
	}

	func cleanup() {
		try? FileManager.default.removeItem(at: root)
	}
}

private struct MobileSyncDevice {
	let store: MobileHostStore
	let material: SessionCredentialMaterialStore
	let masterKey: KeychainSyncMasterKeyStore
	let preferences: CredentialSyncPreferencesStore
	let hostsURL: URL

	@MainActor
	func engine(_ client: any IncrementalHostSyncClient) -> SharedHostSyncEngine {
		SharedHostSyncEngine(
			client: client,
			repository: store,
			credentialSync: preferences,
			masterKeyStore: masterKey,
			materialStore: material
		)
	}
}

private extension CredentialSource {
	var keyPathForTesting: String {
		guard case let .keyFile(path, _) = self else { return "" }
		return path
	}
}
