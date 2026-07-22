import CatermMobileTerminal
import CloudKit
import CloudKitSyncClient
import CredentialSync
import CredentialSyncStore
import CredentialSyncTypes
import Foundation
import KeychainStore
import ManagedKeyStore
import ServerSyncClient
import SessionStore
import SettingsStore
import SnippetStore
import SnippetSyncClient
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
	private var subscriptionShouldFail = false
	private var snapshotFetches = 0
	private var shouldBlockSnapshot = false
	private var snapshotIsBlocked = false
	private var releaseBlockedSnapshot = false
	private var snapshotContinuation: CheckedContinuation<Void, Never>?

	private enum Failure: Error {
		case subscriptionUnavailable
	}

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
		let batch = lock.withLock {
			snapshotFetches += 1
			return HostChangeBatch(
				changedHosts: Array(hosts.values),
				deletedHostIDs: [],
				credentialBlobsByServerId: blobs,
				checkpoint: nil,
				tokenExpired: false,
				mode: .forceFull
			)
		}
		let shouldBlock = lock.withLock {
			guard shouldBlockSnapshot else { return false }
			shouldBlockSnapshot = false
			snapshotIsBlocked = true
			return true
		}
		if shouldBlock {
			await withCheckedContinuation { continuation in
				let resumeImmediately = lock.withLock {
					if releaseBlockedSnapshot {
						releaseBlockedSnapshot = false
						return true
					}
					snapshotContinuation = continuation
					return false
				}
				if resumeImmediately { continuation.resume() }
			}
		}
		return batch
	}

	func commitHostCheckpoint(_: any HostSyncCheckpoint) async throws {}
	func ensureHostSubscription() async throws {
		if lock.withLock({ subscriptionShouldFail }) {
			throw Failure.subscriptionUnavailable
		}
	}
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

	func failSubscription() {
		lock.withLock { subscriptionShouldFail = true }
	}

	func snapshotFetchCount() -> Int {
		lock.withLock { snapshotFetches }
	}

	func blockNextSnapshot() {
		lock.withLock { shouldBlockSnapshot = true }
	}

	func waitUntilSnapshotIsBlocked() async {
		while !lock.withLock({ snapshotIsBlocked }) {
			await Task.yield()
		}
	}

	func releaseSnapshot() {
		let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
			snapshotIsBlocked = false
			guard let continuation = snapshotContinuation else {
				releaseBlockedSnapshot = true
				return nil
			}
			snapshotContinuation = nil
			return continuation
		}
		continuation?.resume()
	}
}

private final class MobileSnippetFixtureClient: IncrementalSnippetSyncClient,
	@unchecked Sendable {
	func preferredSnippetSyncMode() async -> SnippetSyncMode { .forceFull }
	func fetchSnippetChanges() async throws -> SnippetChangeBatch {
		try await fetchSnippetSnapshotAndCheckpoint()
	}
	func fetchSnippetSnapshotAndCheckpoint() async throws -> SnippetChangeBatch {
		SnippetChangeBatch(
			changedSnippets: [],
			deletedSnippetIDs: [],
			checkpoint: nil,
			tokenExpired: false,
			mode: .forceFull
		)
	}
	func commitSnippetCheckpoint(_: any SnippetSyncCheckpoint) async throws {}
	func resetSnippetSyncState() async {}
	func ensureSnippetSubscription() async throws {}
	func deleteSnippetSubscription() async throws {}
	func pushSnippet(_ snippet: Snippet) async throws -> Snippet { snippet }
	func deleteSnippet(id _: UUID) async throws {}
	func hasAnySnippetSyncTokens() async -> Bool { false }
}

private actor MobileAccountSensitiveSpy: AccountSensitiveClient {
	private(set) var hostResetCount = 0
	private(set) var snippetResetCount = 0

	func resetHostSyncState() async { hostResetCount += 1 }
	func deleteHostSubscription() async throws {}
	func resetSnippetSyncState() async { snippetResetCount += 1 }
	func deleteSnippetSubscription() async throws {}
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
	try await deviceA.store.add(jump)
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
	try await deviceA.store.add(storedTarget)
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
	try await deviceA.store.add(passwordHost)
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
	try await device.store.add(SSHHost(
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

@Test("Unknown first identity isolates existing mobile account state")
@MainActor
private func mobileFirstIdentityDoesNotUploadUnknownLocalState() async throws {
	let fixture = try MobileSyncDeviceFixture()
	defer { fixture.cleanup() }
	let defaultsSuite = "MobileFirstIdentity.\(UUID().uuidString)"
	let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
	defer { defaults.removePersistentDomain(forName: defaultsSuite) }
	let client = MobileSyncFixtureClient()
	let accountClient = MobileAccountSensitiveSpy()
	let master = KeychainSyncMasterKeyStore(
		service: fixture.masterKeyService,
		synchronizable: false,
		accessGroup: nil
	)
	let device = fixture.makeDevice(name: "first-identity", masterKey: master)
	try await device.store.add(SSHHost(
		name: "Unknown previous account",
		hostname: "unknown.example.com",
		username: "legacy",
		credential: .agent
	))
	let tracker = AccountIdentityTracker(
		defaults: defaults,
		currentUserRecordID: { CKRecord.ID(recordName: "ACCOUNT-B") },
		tokensExist: { await device.store.hasIdentityBoundState() }
	)
	let runtime = MobileHostSyncRuntime(
		hostStore: device.store,
		syncEngine: device.engine(client),
		client: client,
		credentialSync: device.preferences,
		isSignedIn: { true },
		refreshAccount: {},
		identityBoundary: MobileAccountIdentityBoundary(
			evaluate: {
				await tracker.handleAccountChange(client: accountClient)
			},
			acknowledge: { await tracker.acknowledgeIdentityChange() }
		),
		debounceInterval: 0
	)

	await runtime.launch()
	let hostResetCount = await accountClient.hostResetCount
	let snippetResetCount = await accountClient.snippetResetCount

	#expect(device.store.hosts.isEmpty)
	#expect(client.snapshotFetchCount() == 1)
	#expect(hostResetCount == 1)
	#expect(snippetResetCount == 1)
	#expect(defaults.string(forKey: "cloudkit.lastKnownUserRecordName") == "ACCOUNT-B")
}

@Test("Mobile transition blocks new saves until identity acknowledgement")
@MainActor
private func mobileTransitionKeepsSaveBarrierThroughAcknowledgement() async throws {
	actor AcknowledgementGate {
		var entered = false
		var continuation: CheckedContinuation<Void, Never>?

		func block() async {
			entered = true
			await withCheckedContinuation { continuation = $0 }
		}

		func waitUntilEntered() async {
			while !entered { await Task.yield() }
		}

		func release() {
			continuation?.resume()
			continuation = nil
		}
	}

	let fixture = try MobileSyncDeviceFixture()
	defer { fixture.cleanup() }
	let client = MobileSyncFixtureClient()
	let master = KeychainSyncMasterKeyStore(
		service: fixture.masterKeyService,
		synchronizable: false,
		accessGroup: nil
	)
	let device = fixture.makeDevice(name: "ack-barrier", masterKey: master)
	try await device.store.add(SSHHost(
		name: "Account A",
		hostname: "a.example.com",
		username: "a",
		credential: .agent
	))
	let gate = AcknowledgementGate()
	let runtime = MobileHostSyncRuntime(
		hostStore: device.store,
		syncEngine: device.engine(client),
		client: client,
		credentialSync: device.preferences,
		isSignedIn: { true },
		refreshAccount: {},
		identityBoundary: MobileAccountIdentityBoundary(
			evaluate: { .identityChanged },
			acknowledge: { await gate.block() }
		),
		debounceInterval: 0
	)
	let transition = Task { @MainActor in await runtime.launch() }
	await gate.waitUntilEntered()

	let writer = MobileCredentialWriter(keychain: KeychainStore(
		service: "com.caterm.test.ack-barrier.\(UUID().uuidString)",
		accessGroup: nil
	))
	let coordinator = MobileHostSaveCoordinator(
		hostStore: device.store,
		credentialWriter: writer,
		prepareCredentialSyncForSave: { _ in }
	)
	let accountBHost = SSHHost(
		name: "Account B",
		hostname: "b.example.com",
		username: "b",
		credential: .agent
	)
	let blockedSave = Task { @MainActor in
		do {
			try await coordinator.save(
				MobileHostDraftPayload(host: accountBHost, secret: nil)
			)
			return false
		} catch {
			return true
		}
	}
	let saveWasBlocked = await blockedSave.value
	#expect(saveWasBlocked)
	#expect(device.store.hosts.isEmpty)
	#expect(device.store.isAccountTransitionInProgress)

	await gate.release()
	_ = await transition.value
	#expect(!device.store.isAccountTransitionInProgress)

	try await coordinator.save(
		MobileHostDraftPayload(host: accountBHost, secret: nil)
	)
	#expect(device.store.hosts.map(\.id) == [accountBHost.id])
}

@Test("Account switch drains a cancelled stale Host fetch before loading B")
@MainActor
private func mobileAccountTransitionRejectsStaleInFlightBatch() async throws {
	let fixture = try MobileSyncDeviceFixture()
	defer { fixture.cleanup() }
	let client = MobileSyncFixtureClient()
	_ = try await client.createHost(RemoteHostCreateInput(
		name: "Account A remote",
		hostname: "a-remote.example.com",
		port: 22,
		username: "a",
		jumpHostServerId: nil,
		forwards: [],
		icon: nil,
		organization: HostOrganization(),
		metadataUpdatedAt: Date()
	))
	client.blockNextSnapshot()
	let master = KeychainSyncMasterKeyStore(
		service: fixture.masterKeyService,
		synchronizable: false,
		accessGroup: nil
	)
	let device = fixture.makeDevice(name: "stale-batch", masterKey: master)
	let account = MobileSyncAccountState()
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
		)
	)

	let launch = Task { @MainActor in await runtime.launch() }
	await client.waitUntilSnapshotIsBlocked()
	account.set(identity: "account-b", signedIn: true)
	client.switchToEmptyAccount()
	let transition = Task { @MainActor in await runtime.accountDidChange() }
	await Task.yield()
	client.releaseSnapshot()
	await launch.value
	_ = await transition.value

	#expect(!device.store.hosts.contains { $0.name == "Account A remote" })
	#expect(client.snapshotFetchCount() == 2)
}

@Test("Mobile subscription failure remains visible and skips Host fetch")
@MainActor
private func mobileSubscriptionFailureIsNotReportedUpToDate() async throws {
	let fixture = try MobileSyncDeviceFixture()
	defer { fixture.cleanup() }
	let client = MobileSyncFixtureClient()
	client.failSubscription()
	let master = KeychainSyncMasterKeyStore(
		service: fixture.masterKeyService,
		synchronizable: false,
		accessGroup: nil
	)
	let device = fixture.makeDevice(name: "subscription-failure", masterKey: master)
	let runtime = MobileHostSyncRuntime(
		hostStore: device.store,
		syncEngine: device.engine(client),
		client: client,
		credentialSync: device.preferences,
		isSignedIn: { true },
		refreshAccount: {}
	)

	await runtime.launch()

	guard case .temporarilyUnavailable = runtime.state else {
		Issue.record("Expected a visible subscription failure")
		return
	}
	#expect(client.snapshotFetchCount() == 0)
}

@Test("Temporary account failure keeps related sync suspended until recovery")
@MainActor
private func mobileTemporaryAccountFailureKeepsRelatedLaneClosed() async throws {
	let fixture = try MobileSyncDeviceFixture()
	defer { fixture.cleanup() }
	let client = MobileSyncFixtureClient()
	let master = KeychainSyncMasterKeyStore(
		service: fixture.masterKeyService,
		synchronizable: false
	)
	let device = fixture.makeDevice(name: "temporary-account", masterKey: master)
	var outcome = AccountChangeOutcome.temporarilyUnavailable("Account unavailable")
	var beginCount = 0
	var resumeCount = 0
	let runtime = MobileHostSyncRuntime(
		hostStore: device.store,
		syncEngine: device.engine(client),
		client: client,
		credentialSync: device.preferences,
		isSignedIn: { true },
		refreshAccount: {},
		identityBoundary: MobileAccountIdentityBoundary(
			evaluate: { outcome },
			acknowledge: {},
			beginRelatedSyncSuspension: { beginCount += 1 },
			resumeRelatedSync: { _ in resumeCount += 1 }
		)
	)

	await runtime.launch()

	#expect(beginCount == 1)
	#expect(resumeCount == 0)
	guard case .temporarilyUnavailable = runtime.state else {
		Issue.record("Expected account unavailability to remain visible")
		return
	}

	outcome = .unchanged
	_ = await runtime.accountDidChange()

	#expect(beginCount == 2)
	#expect(resumeCount == 1)
}

@Test("Related sync identity gate does not run a Host pass")
@MainActor
private func mobileRelatedSyncIdentityGateDoesNotFetchHosts() async throws {
	let fixture = try MobileSyncDeviceFixture()
	defer { fixture.cleanup() }
	let client = MobileSyncFixtureClient()
	let master = KeychainSyncMasterKeyStore(
		service: fixture.masterKeyService,
		synchronizable: false
	)
	let device = fixture.makeDevice(name: "related-gate", masterKey: master)
	var resumeCount = 0
	let runtime = MobileHostSyncRuntime(
		hostStore: device.store,
		syncEngine: device.engine(client),
		client: client,
		credentialSync: device.preferences,
		isSignedIn: { true },
		refreshAccount: {},
		identityBoundary: MobileAccountIdentityBoundary(
			evaluate: { .unchanged },
			acknowledge: {},
			resumeRelatedSync: { _ in resumeCount += 1 }
		)
	)

	let result = await runtime.prepareForRelatedSync()

	#expect(result == .noData)
	#expect(client.snapshotFetchCount() == 0)
	#expect(resumeCount == 1)
}

@Test("Related sync identity gate resubmits interrupted Host work")
@MainActor
private func mobileRelatedSyncIdentityGatePreservesActiveHostRequest() async throws {
	let fixture = try MobileSyncDeviceFixture()
	defer { fixture.cleanup() }
	let client = MobileSyncFixtureClient()
	client.blockNextSnapshot()
	let master = KeychainSyncMasterKeyStore(
		service: fixture.masterKeyService,
		synchronizable: false
	)
	let device = fixture.makeDevice(name: "related-gate-active", masterKey: master)
	let runtime = MobileHostSyncRuntime(
		hostStore: device.store,
		syncEngine: device.engine(client),
		client: client,
		credentialSync: device.preferences,
		isSignedIn: { true },
		refreshAccount: {},
		identityBoundary: MobileAccountIdentityBoundary(
			evaluate: { .unchanged },
			acknowledge: {}
		)
	)
	let launch = Task { @MainActor in await runtime.launch() }
	await client.waitUntilSnapshotIsBlocked()

	let gate = Task { @MainActor in await runtime.prepareForRelatedSync() }
	await Task.yield()
	client.releaseSnapshot()
	_ = await launch.value
	#expect(await gate.value == .noData)
	for _ in 0..<1_000 {
		if client.snapshotFetchCount() == 2 { break }
		await Task.yield()
	}

	#expect(client.snapshotFetchCount() == 2)
}

@Test("Related sync identity gate queues Host mutations created while gated")
@MainActor
private func mobileRelatedSyncIdentityGateQueuesNewHostMutation() async throws {
	actor IdentityGate {
		private var entered = false
		private var continuation: CheckedContinuation<Void, Never>?

		func evaluate() async -> AccountChangeOutcome {
			entered = true
			await withCheckedContinuation { continuation = $0 }
			return .unchanged
		}

		func waitUntilEntered() async {
			while !entered { await Task.yield() }
		}

		func release() {
			continuation?.resume()
			continuation = nil
		}
	}

	let fixture = try MobileSyncDeviceFixture()
	defer { fixture.cleanup() }
	let client = MobileSyncFixtureClient()
	let master = KeychainSyncMasterKeyStore(
		service: fixture.masterKeyService,
		synchronizable: false
	)
	let device = fixture.makeDevice(name: "related-gate-mutation", masterKey: master)
	let identityGate = IdentityGate()
	let runtime = MobileHostSyncRuntime(
		hostStore: device.store,
		syncEngine: device.engine(client),
		client: client,
		credentialSync: device.preferences,
		isSignedIn: { true },
		refreshAccount: {},
		identityBoundary: MobileAccountIdentityBoundary(
			evaluate: { await identityGate.evaluate() },
			acknowledge: {}
		),
		debounceInterval: 0
	)
	let gate = Task { @MainActor in await runtime.prepareForRelatedSync() }
	await identityGate.waitUntilEntered()

	try await device.store.add(SSHHost(
		name: "Created during gate",
		hostname: "gate.example.com",
		username: "ops",
		credential: .agent
	))
	for _ in 0..<20 { await Task.yield() }
	#expect(client.snapshotFetchCount() == 0)

	await identityGate.release()
	#expect(await gate.value == .noData)
	for _ in 0..<1_000 {
		if client.snapshotFetchCount() == 1 { break }
		await Task.yield()
	}

	#expect(client.snapshotFetchCount() == 1)
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
	let auxiliaryRoot = FileManager.default.temporaryDirectory
		.appendingPathComponent("mobile-composition-\(UUID().uuidString)")
	defer { try? FileManager.default.removeItem(at: auxiliaryRoot) }
	let snippetStore = SnippetStore(directory: auxiliaryRoot)
	let snippetClient = MobileSnippetFixtureClient()
	let snippetSync = SnippetSyncStore(store: snippetStore, client: snippetClient)
	let snippetRuntime = MobileSnippetSyncRuntime(
		store: snippetStore,
		sync: snippetSync,
		client: snippetClient,
		isSignedIn: { false },
		refreshAccount: {}
	)
	let settingsStore = SettingsStore(
		settings: CatermSettings(global: CatermSettings.defaultsSeed),
		path: auxiliaryRoot.appendingPathComponent("settings.plist")
	)
	let composition = MobileAppComposition(
		hostStore: device.store,
		credentialWriter: writer,
		syncRuntime: runtime,
		snippetStore: snippetStore,
		snippetSyncRuntime: snippetRuntime,
		settingsStore: settingsStore,
		settingsSync: nil,
		terminalSessionFactory: MobileTerminalSessionFactory { _ in
			throw MobileCredentialUnavailableReason.credentialReadFailed
		}
	)

	#expect(composition.hostStore === device.store)
	#expect(composition.syncRuntime === runtime)
	#expect(composition.syncRuntime.hostStore === composition.hostStore)
	#expect(composition.snippetStore === snippetStore)
	#expect(composition.snippetSyncRuntime.store === composition.snippetStore)
	#expect(composition.settingsStore === settingsStore)
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

@Test("Mobile composition enables credential receiving without generating a key")
@MainActor
private func mobileCompositionPreparesCredentialSyncOnProductionPath() async throws {
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(
		"mobile-credential-composition-\(UUID().uuidString)",
		isDirectory: true
	)
	defer { try? FileManager.default.removeItem(at: root) }
	let suiteName = "MobileCredentialComposition.\(UUID().uuidString)"
	let defaults = try #require(UserDefaults(suiteName: suiteName))
	defer { defaults.removePersistentDomain(forName: suiteName) }
	let master = KeychainSyncMasterKeyStore(
		service: "com.caterm.test.mobile-composition-master.\(UUID().uuidString)",
		synchronizable: false,
		accessGroup: nil
	)
	let composition = MobileAppComposition.live(
		hostsURL: root.appendingPathComponent("hosts.json"),
		applicationSupportURL: root,
		credentialDefaults: defaults,
		masterKeyStore: master,
		cloudKitEnabled: false
	)

	let persisted = CredentialSyncPreferencesStore(defaults: defaults)
	#expect(persisted.prefs.state == .enabled)
	#expect(try await master.lookupAny() == nil)

	try await composition.prepareCredentialSyncForSave { true }
	let generated = try #require(try await master.lookupAny())
	defer { Task { await master.remove(keyID: generated.keyID) } }
	#expect(CredentialSyncPreferencesStore(defaults: defaults).prefs.state == .enabled)
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
	try await deviceA.store.add(SSHHost(
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
