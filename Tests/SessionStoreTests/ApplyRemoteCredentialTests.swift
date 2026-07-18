import XCTest
import KeychainStore
import ManagedKeyStore
import SSHCommandBuilder
@testable import SessionStore

@MainActor
final class ApplyRemoteCredentialTests: XCTestCase {
	private var hostsURL: URL!
	private var store: SessionStore!
	private var managedKeys: ManagedKeyStore!
	private var managedKeysURL: URL!

	override func setUp() async throws {
		try await super.setUp()
		hostsURL = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID()).json")
		let keychain = KeychainStore(
			service: "com.caterm.test.apply-remote-credential.\(UUID())",
			accessGroup: nil
		)
		managedKeysURL = hostsURL.deletingLastPathComponent()
			.appendingPathComponent("managed-\(UUID())")
		managedKeys = ManagedKeyStore(rootURL: managedKeysURL)
		let materialStore = SessionCredentialMaterialStore(
			secrets: InMemoryCredentialSecretStore(),
			managedKeyStore: managedKeys
		)
		store = SessionStore(
			askpassPath: "/x", knownHostsCaterm: "/A",
			knownHostsUser: "/B", accessGroup: nil,
			hostsURL: hostsURL, keychain: keychain,
			managedKeyStore: managedKeys,
			credentialMaterialStore: materialStore
		)
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: hostsURL)
		try? FileManager.default.removeItem(at: managedKeysURL)
		try await super.tearDown()
	}

	func test_applyPasswordReference_keepsCredentialPassword() async throws {
		var host = Host(name: "B", hostname: "h", port: 22, username: "u", credential: .password)
		try store.addHost(host)
		host = store.hosts.first { $0.id == host.id }!
		try await applyRemoteMaterial(
			HostSecrets(password: Data("password".utf8)),
			to: host.id
		)
		XCTAssertEqual(store.hosts.first { $0.id == host.id }!.credential, .password)
	}

	func test_applyPrivateKey_flipsCredentialToKeyFile() async throws {
		var host = Host(name: "B", hostname: "h", port: 22, username: "u", credential: .password)
		try store.addHost(host)
		host = store.hosts.first { $0.id == host.id }!
		try await applyRemoteMaterial(
			HostSecrets(
				passphrase: Data("passphrase".utf8),
				privateKeyBytes: Data("private-key".utf8)
			),
			to: host.id
		)
		let cred = store.hosts.first { $0.id == host.id }!.credential
		if case let .keyFile(path, hasPassphrase) = cred {
			XCTAssertEqual(path, managedKeys.path(hostId: host.id).path)
			XCTAssertTrue(hasPassphrase)
		} else { XCTFail("expected .keyFile, got \(cred)") }
	}

	func test_applyAgent_keepsCredentialUntouched() async throws {
		// No password, no private key → should leave .agent or any other
		// pre-existing credential alone.
		var host = Host(name: "B", hostname: "h", port: 22, username: "u", credential: .agent)
		try store.addHost(host)
		host = store.hosts.first { $0.id == host.id }!
		try await applyRemoteMaterial(HostSecrets(), to: host.id)
		XCTAssertEqual(store.hosts.first { $0.id == host.id }!.credential, .agent)
	}

	func test_localCommitBlocksAndThenRejectsStaleRemoteWrite() async throws {
		let hostId = UUID()
		let expectedGeneration = await store.credentialMaterialStore
			.currentGeneration(for: hostId)
		let localCommit = try await store.credentialMaterialStore.applyLocal(
			HostSecrets(),
			source: .agent,
			for: hostId
		)
		let remoteWrite = Task {
			try await store.credentialMaterialStore.applyRemote(
				HostSecrets(),
				for: hostId,
				expectedGeneration: expectedGeneration
			)
		}
		await waitForQueuedTransactions(1, hostId: hostId)

		await store.credentialMaterialStore.finalizeLocalCommit(localCommit)
		let commit = try await remoteWrite.value

		XCTAssertNil(commit)
	}

	func test_sourceOnlyLocalChangeAdvancesGeneration() async throws {
		let host = SSHHost(
			name: "source-only",
			hostname: "host.example",
			username: "root",
			credential: .keyFile(
				keyPath: "/legacy/id_source_only",
				hasPassphrase: false
			)
		)
		try store.addHost(host)
		let previousGeneration = await store.credentialMaterialStore
			.currentGeneration(for: host.id)

		try await store.setHostCredentialMaterial(
			secrets: HostSecrets(),
			credentialSource: .password,
			for: host.id
		)

		let currentGeneration = await store.credentialMaterialStore
			.currentGeneration(for: host.id)
		XCTAssertEqual(currentGeneration, previousGeneration + 1)
		let updated = try XCTUnwrap(store.hosts.first { $0.id == host.id })
		XCTAssertEqual(updated.credential, .password)
		XCTAssertTrue(updated.credentialMaterialDirty)
		let staleRemote = try await store.credentialMaterialStore.applyRemote(
			HostSecrets(password: Data("remote".utf8)),
			for: host.id,
			expectedGeneration: previousGeneration
		)
		XCTAssertNil(staleRemote)
	}

	func test_snapshotWaitsForLocalMetadataCommitBoundary() async throws {
		let hostId = UUID()
		let localCommit = try await store.credentialMaterialStore.applyLocal(
			HostSecrets(),
			source: .agent,
			for: hostId
		)
		let snapshot = Task {
			try await store.credentialMaterialStore.snapshot(for: hostId)
		}
		await waitForQueuedTransactions(1, hostId: hostId)

		await store.credentialMaterialStore.finalizeLocalCommit(localCommit)
		let result = try await snapshot.value

		XCTAssertEqual(result.generation, 1)
	}

	func testCredentialAvailabilityRetriesSourceAfterQueuedCommit() async throws {
		let host = SSHHost(
			name: "availability",
			hostname: "host.example",
			username: "root",
			credential: .password
		)
		try store.addHost(host)
		let localCommit = try await store.credentialMaterialStore.applyLocal(
			HostSecrets(),
			source: .agent,
			for: host.id
		)
		let availability = Task { @MainActor in
			await store.needsCredentialSetup(host)
		}
		await waitForQueuedTransactions(1, hostId: host.id)

		try store.setCredentialOnly(.agent, for: host.id)
		await store.credentialMaterialStore.finalizeLocalCommit(localCommit)

		let requiresSetup = await availability.value
		XCTAssertFalse(requiresSetup)
	}

	func test_snapshotReturnsCommittedManagedKeyAfterProvisionalRollback() async throws {
		let hostId = UUID()
		let committedKey = Data("committed-key".utf8)
		_ = try await managedKeys.write(hostId: hostId, bytes: committedKey)
		let localCommit = try await store.credentialMaterialStore.applyLocal(
			HostSecrets(privateKeyBytes: Data("provisional-key".utf8)),
			source: .keyFile(path: "", hasPassphrase: false),
			for: hostId
		)
		let snapshot = Task {
			try await store.credentialMaterialStore.snapshot(for: hostId)
		}
		await waitForQueuedTransactions(1, hostId: hostId)

		try await store.credentialMaterialStore.rollbackLocalCommit(localCommit)
		let result = try await snapshot.value

		XCTAssertEqual(result.generation, 0)
		XCTAssertEqual(result.managedPrivateKey, committedKey)
	}

	func test_generationValidationWaitsAndRejectsFinalizedLocalCommit() async throws {
		let hostId = UUID()
		let localCommit = try await store.credentialMaterialStore.applyLocal(
			HostSecrets(),
			source: .agent,
			for: hostId
		)
		let validation = Task {
			try await store.credentialMaterialStore.beginGenerationValidation(
				for: hostId,
				expectedGeneration: 0
			)
		}
		await waitForQueuedTransactions(1, hostId: hostId)

		await store.credentialMaterialStore.finalizeLocalCommit(localCommit)

		let result = try await validation.value
		XCTAssertNil(result)
	}

	func test_terminalCallsAreIdempotentAndLeaveQueueUsable() async throws {
		let hostId = UUID()
		let commit = try await store.credentialMaterialStore.applyLocal(
			HostSecrets(),
			source: .agent,
			for: hostId
		)

		try await store.credentialMaterialStore.rollbackLocalCommit(commit)
		try await store.credentialMaterialStore.rollbackLocalCommit(commit)
		await store.credentialMaterialStore.finalizeLocalCommit(commit)

		let next = try await store.credentialMaterialStore.applyLocal(
			HostSecrets(),
			source: .agent,
			for: hostId
		)
		await store.credentialMaterialStore.finalizeLocalCommit(next)
		let generation = await store.credentialMaterialStore
			.currentGeneration(for: hostId)
		XCTAssertEqual(generation, 1)
	}

	func test_failedRollbackSurfacesErrorAndReleasesHostLease() async throws {
		let fixture = try makeInMemoryDeletionFixture()
		defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
		let hostId = UUID()
		let commit = try await fixture.materialStore.applyLocal(
			HostSecrets(password: Data("provisional".utf8)),
			source: .password,
			for: hostId
		)
		fixture.secrets.failNextDelete()

		do {
			try await fixture.materialStore.rollbackLocalCommit(commit)
			XCTFail("rollback cleanup failure must be surfaced")
		} catch CredentialSecretTestError.injectedFailure {
			// Expected.
		}
		let generationAfterFailure = await fixture.materialStore
			.currentGeneration(for: hostId)
		XCTAssertEqual(generationAfterFailure, 1)
		let staleValidation = try await fixture.materialStore
			.beginGenerationValidation(for: hostId, expectedGeneration: 0)
		XCTAssertNil(staleValidation)

		let next = try await fixture.materialStore.applyLocal(
			HostSecrets(),
			source: .agent,
			for: hostId
		)
		await fixture.materialStore.finalizeLocalCommit(next)
		let generation = await fixture.materialStore.currentGeneration(for: hostId)
		XCTAssertEqual(generation, 2)
	}

	func test_failedDiscardSurfacesErrorAndReleasesHostLease() async throws {
		let fixture = try makeInMemoryDeletionFixture()
		defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
		let hostId = UUID()
		let commit = try await fixture.materialStore.applyLocal(
			HostSecrets(password: Data("provisional".utf8)),
			source: .password,
			for: hostId
		)
		fixture.secrets.failNextDeleteAll()

		do {
			try await fixture.materialStore
				.discardLocalCommitForDeletedHost(commit)
			XCTFail("discard cleanup failure must be surfaced")
		} catch CredentialSecretTestError.injectedFailure {
			// Expected.
		}
		let generationAfterFailure = await fixture.materialStore
			.currentGeneration(for: hostId)
		XCTAssertEqual(generationAfterFailure, 1)
		let staleValidation = try await fixture.materialStore
			.beginGenerationValidation(for: hostId, expectedGeneration: 0)
		XCTAssertNil(staleValidation)

		let next = try await fixture.materialStore.applyLocal(
			HostSecrets(),
			source: .agent,
			for: hostId
		)
		await fixture.materialStore.finalizeLocalCommit(next)
		let generation = await fixture.materialStore.currentGeneration(for: hostId)
		XCTAssertEqual(generation, 2)
	}

	func test_accountResetRejectsQueuedOldWorkAndWaitsForActiveCommit() async throws {
		let fixture = try makeInMemoryDeletionFixture()
		defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
		let hostId = UUID()
		let finalKey = Data("final-key".utf8)
		let active = try await fixture.materialStore.applyLocal(
			HostSecrets(privateKeyBytes: finalKey),
			source: .keyFile(path: "", hasPassphrase: false),
			for: hostId
		)
		let queued = Task {
			try await fixture.materialStore.applyLocal(
				HostSecrets(),
				source: .agent,
				for: hostId
			)
		}
		await waitForQueuedTransactions(
			1,
			hostId: hostId,
			materialStore: fixture.materialStore
		)
		let reset = Task {
			try await fixture.materialStore.resetManagedKeysForAccountChange()
		}

		do {
			_ = try await queued.value
			XCTFail("old-account queued work must not resume after reset")
		} catch SessionCredentialMaterialError.supersededByAccountReset {
			// Expected.
		}
		XCTAssertEqual(try fixture.managedKeys.read(hostId: hostId), finalKey)

		await fixture.materialStore.finalizeLocalCommit(active)
		try await reset.value

		XCTAssertNil(try fixture.managedKeys.read(hostId: hostId))
		let generation = await fixture.materialStore.currentGeneration(for: hostId)
		XCTAssertEqual(generation, 2)
		let next = try await fixture.materialStore.applyLocal(
			HostSecrets(),
			source: .agent,
			for: hostId
		)
		await fixture.materialStore.finalizeLocalCommit(next)
	}

	func test_accountResetAdvancesGenerationForUntouchedHost() async throws {
		let fixture = try makeInMemoryDeletionFixture()
		defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
		let untouchedHostId = UUID()
		let before = await fixture.materialStore.currentGeneration(
			for: untouchedHostId
		)

		try await fixture.materialStore.resetManagedKeysForAccountChange()

		let after = await fixture.materialStore.currentGeneration(
			for: untouchedHostId
		)
		XCTAssertEqual(after, before + 1)
	}

	func test_failedAccountResetReleasesGlobalBarrier() async throws {
		let parent = FileManager.default.temporaryDirectory
			.appendingPathComponent("credential-reset-failure-\(UUID())")
		let managedRoot = parent.appendingPathComponent("keys")
		try FileManager.default.createDirectory(
			at: parent,
			withIntermediateDirectories: true
		)
		defer {
			try? FileManager.default.setAttributes(
				[.posixPermissions: 0o700],
				ofItemAtPath: parent.path
			)
			try? FileManager.default.removeItem(at: parent)
		}
		let managedKeys = ManagedKeyStore(rootURL: managedRoot)
		_ = try await managedKeys.write(
			hostId: UUID(),
			bytes: Data("seed".utf8)
		)
		let materialStore = SessionCredentialMaterialStore(
			secrets: InMemoryCredentialSecretStore(),
			managedKeyStore: managedKeys
		)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o500],
			ofItemAtPath: parent.path
		)

		do {
			try await materialStore.resetManagedKeysForAccountChange()
			XCTFail("filesystem failure must be surfaced")
		} catch ManagedKeyStore.Error.wipeFailed {
			// Expected.
		}
		let generationAfterFailure = await materialStore.currentGeneration(
			for: UUID()
		)
		XCTAssertEqual(generationAfterFailure, 1)

		let hostId = UUID()
		let next = try await materialStore.applyLocal(
			HostSecrets(),
			source: .agent,
			for: hostId
		)
		await materialStore.finalizeLocalCommit(next)
		let generation = await materialStore.currentGeneration(for: hostId)
		XCTAssertEqual(generation, 2)
	}

	func test_migrationRollsBackWhenCredentialSourceChangesWhileQueued() async throws {
		let fixture = try makeInMemoryDeletionFixture()
		defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
		let externalSource = CredentialSource.keyFile(
			keyPath: "/external/id_test",
			hasPassphrase: false
		)
		let host = SSHHost(
			name: "migration",
			hostname: "host.example",
			username: "root",
			credential: externalSource
		)
		try fixture.store.addHost(host)
		let active = try await fixture.materialStore.beginGenerationValidation(
			for: host.id,
			expectedGeneration: 0
		)
		guard let active else {
			return XCTFail("expected a material validation lease")
		}
		let migration = Task { @MainActor in
			try await fixture.store.migrateExternalPrivateKey(
				Data("legacy-key".utf8),
				from: externalSource,
				for: host.id
			)
		}
		await waitForQueuedTransactions(
			1,
			hostId: host.id,
			materialStore: fixture.materialStore
		)

		try fixture.store.setCredentialOnly(.password, for: host.id)
		await fixture.materialStore.finishGenerationValidation(active)
		let migrated = try await migration.value

		XCTAssertFalse(migrated)
		XCTAssertEqual(
			fixture.store.hosts.first(where: { $0.id == host.id })?.credential,
			.password
		)
		XCTAssertNil(try fixture.managedKeys.read(hostId: host.id))
	}

	func test_deleteWaitsForLocalCommitAndRemovesFinalMaterial() async throws {
		let fixture = try makeInMemoryDeletionFixture()
		defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
		let host = SSHHost(
			name: "delete-me",
			hostname: "host.example",
			username: "root",
			credential: .agent
		)
		try fixture.store.addHost(host)
		try await fixture.store.setHostCredentialMaterial(
			secrets: HostSecrets(
				password: Data("password".utf8),
				privateKeyBytes: Data("initial-key".utf8)
			),
			credentialSource: .keyFile(keyPath: "", hasPassphrase: false),
			for: host.id
		)
		let localCommit = try await fixture.materialStore.applyLocal(
			HostSecrets(privateKeyBytes: Data("final-key".utf8)),
			source: .keyFile(path: "", hasPassphrase: false),
			for: host.id
		)
		let deletion = Task { @MainActor in
			try await fixture.store.deleteHost(id: host.id)
		}
		await waitForQueuedTransactions(
			1,
			hostId: host.id,
			materialStore: fixture.materialStore
		)

		await fixture.materialStore.finalizeLocalCommit(localCommit)
		try await deletion.value

		XCTAssertTrue(fixture.store.hosts.isEmpty)
		XCTAssertNil(try fixture.managedKeys.read(hostId: host.id))
		XCTAssertFalse(fixture.secrets.contains(prefix: host.id.uuidString))
	}

	func test_deletePersistenceFailureRestoresCredentialMaterial() async throws {
		let fixture = try makeInMemoryDeletionFixture()
		defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
		let host = SSHHost(
			name: "keep-me",
			hostname: "host.example",
			username: "root",
			credential: .agent
		)
		try fixture.store.addHost(host)
		let key = Data("private-key".utf8)
		try await fixture.store.setHostCredentialMaterial(
			secrets: HostSecrets(
				password: Data("password".utf8),
				privateKeyBytes: key
			),
			credentialSource: .keyFile(keyPath: "", hasPassphrase: false),
			for: host.id
		)
		try FileManager.default.removeItem(at: fixture.hostsURL)
		try FileManager.default.createDirectory(
			at: fixture.hostsURL,
			withIntermediateDirectories: false
		)

		do {
			try await fixture.store.deleteHost(id: host.id)
			XCTFail("persistence failure must reject deletion")
		} catch {
			// Expected.
		}

		XCTAssertEqual(fixture.store.hosts.map(\.id), [host.id])
		XCTAssertEqual(try fixture.managedKeys.read(hostId: host.id), key)
		XCTAssertEqual(
			try fixture.secrets.get(
				account: "\(host.id.uuidString).password"
			),
			"password"
		)
	}

	func test_cancelledQueuedLocalMutationNeverAdvancesGeneration() async throws {
		let hostId = UUID()
		let remoteCommit = try await store.credentialMaterialStore.applyRemote(
			HostSecrets(),
			for: hostId,
			expectedGeneration: 0
		)
		let localWrite = Task {
			try await store.credentialMaterialStore.applyLocal(
				HostSecrets(),
				source: .agent,
				for: hostId
			)
		}
		await waitForQueuedTransactions(1, hostId: hostId)

		localWrite.cancel()
		do {
			_ = try await localWrite.value
			XCTFail("cancelled queued mutation must not execute")
		} catch is CancellationError {
			// Expected.
		}

		let generation = await store.credentialMaterialStore
			.currentGeneration(for: hostId)
		XCTAssertEqual(generation, 0)
		if let remoteCommit {
			try await store.credentialMaterialStore
				.resolveRemoteCommit(remoteCommit, as: .commit)
		} else {
			XCTFail("expected a provisional remote commit")
		}
	}

	func test_rolledBackLocalMutationKeepsGenerationAndUnblocksRemote() async throws {
		let hostId = UUID()
		let localCommit = try await store.credentialMaterialStore.applyLocal(
			HostSecrets(),
			source: .agent,
			for: hostId
		)
		let remoteWrite = Task {
			try await store.credentialMaterialStore.applyRemote(
				HostSecrets(),
				for: hostId,
				expectedGeneration: 0
			)
		}
		await waitForQueuedTransactions(1, hostId: hostId)

		try await store.credentialMaterialStore.rollbackLocalCommit(localCommit)
		let remoteCommit = try await remoteWrite.value
		let generation = await store.credentialMaterialStore
			.currentGeneration(for: hostId)

		XCTAssertEqual(generation, 0)
		if let remoteCommit {
			try await store.credentialMaterialStore
				.resolveRemoteCommit(remoteCommit, as: .commit)
		} else {
			XCTFail("rolled-back local mutation must not stale the remote write")
		}
	}

	func test_finalizedRemoteCommitInvalidatesOlderMaterialSnapshot() async throws {
		let hostId = UUID()
		let before = await store.credentialMaterialStore.currentGeneration(
			for: hostId
		)
		let commit = try await store.credentialMaterialStore.applyRemote(
			HostSecrets(),
			for: hostId,
			expectedGeneration: before
		)
		guard let commit else {
			return XCTFail("expected a provisional remote commit")
		}

		try await store.credentialMaterialStore.resolveRemoteCommit(
			commit,
			as: .commit
		)

		let after = await store.credentialMaterialStore.currentGeneration(
			for: hostId
		)
		XCTAssertEqual(after, before + 1)
		let staleValidation = try await store.credentialMaterialStore
			.beginGenerationValidation(
				for: hostId,
				expectedGeneration: before
			)
		XCTAssertNil(staleValidation)
	}

	func test_discardedRemoteCommitInvalidatesOlderMaterialSnapshot() async throws {
		let hostId = UUID()
		let before = await store.credentialMaterialStore.currentGeneration(
			for: hostId
		)
		let commit = try await store.credentialMaterialStore.applyRemote(
			HostSecrets(password: Data("remote".utf8)),
			for: hostId,
			expectedGeneration: before
		)
		guard let commit else {
			return XCTFail("expected a provisional remote commit")
		}

		try await store.credentialMaterialStore.resolveRemoteCommit(
			commit,
			as: .discard
		)

		let after = await store.credentialMaterialStore.currentGeneration(
			for: hostId
		)
		XCTAssertEqual(after, before + 1)
		let staleValidation = try await store.credentialMaterialStore
			.beginGenerationValidation(
				for: hostId,
				expectedGeneration: before
			)
		XCTAssertNil(staleValidation)
	}

	func test_failedLocalMaterialWriteDoesNotAdvanceGeneration() async throws {
		let hostId = UUID()
		do {
			_ = try await store.credentialMaterialStore.applyLocal(
				HostSecrets(
					privateKeyBytes: Data(count: ManagedKeyStore.maxBytes + 1)
				),
				source: .keyFile(path: "", hasPassphrase: false),
				for: hostId
			)
			XCTFail("oversized managed key must fail")
		} catch ManagedKeyStore.Error.tooLarge {
			// Expected.
		}

		let generation = await store.credentialMaterialStore
			.currentGeneration(for: hostId)
		XCTAssertEqual(generation, 0)
		let remoteCommit = try await store.credentialMaterialStore.applyRemote(
			HostSecrets(),
			for: hostId,
			expectedGeneration: 0
		)
		if let remoteCommit {
			try await store.credentialMaterialStore
				.resolveRemoteCommit(remoteCommit, as: .commit)
		} else {
			XCTFail("failed local write must not stale the remote write")
		}
	}

	func test_localMutationsAcquireHostLeaseInFIFOOrder() async throws {
		let hostId = UUID()
		let firstCommit = try await store.credentialMaterialStore.applyLocal(
			HostSecrets(),
			source: .agent,
			for: hostId
		)
		let secondWrite = Task {
			try await store.credentialMaterialStore.applyLocal(
				HostSecrets(),
				source: .password,
				for: hostId
			)
		}
		await waitForQueuedTransactions(1, hostId: hostId)
		let thirdWrite = Task {
			try await store.credentialMaterialStore.applyLocal(
				HostSecrets(),
				source: .agent,
				for: hostId
			)
		}
		await waitForQueuedTransactions(2, hostId: hostId)

		await store.credentialMaterialStore.finalizeLocalCommit(firstCommit)
		let secondCommit = try await secondWrite.value
		let generationAfterSecond = await store.credentialMaterialStore
			.currentGeneration(for: hostId)
		XCTAssertEqual(secondCommit.source, .password)
		XCTAssertEqual(generationAfterSecond, 1)
		await waitForQueuedTransactions(1, hostId: hostId)

		await store.credentialMaterialStore.finalizeLocalCommit(secondCommit)
		let thirdCommit = try await thirdWrite.value
		let generationBeforeThirdCommit = await store.credentialMaterialStore
			.currentGeneration(for: hostId)
		XCTAssertEqual(thirdCommit.source, .agent)
		XCTAssertEqual(generationBeforeThirdCommit, 2)
		await store.credentialMaterialStore.finalizeLocalCommit(thirdCommit)
		let finalGeneration = await store.credentialMaterialStore
			.currentGeneration(for: hostId)
		XCTAssertEqual(finalGeneration, 3)
	}

	private func makeInMemoryDeletionFixture() throws -> DeletionFixture {
		let rootURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("credential-deletion-\(UUID())")
		try FileManager.default.createDirectory(
			at: rootURL,
			withIntermediateDirectories: true
		)
		let hostsURL = rootURL.appendingPathComponent("hosts.json")
		let secrets = InMemoryCredentialSecretStore()
		let managedKeys = ManagedKeyStore(
			rootURL: rootURL.appendingPathComponent("keys")
		)
		let materialStore = SessionCredentialMaterialStore(
			secrets: secrets,
			managedKeyStore: managedKeys
		)
		let sessionStore = SessionStore(
			askpassPath: "/x",
			knownHostsCaterm: "/A",
			knownHostsUser: "/B",
			accessGroup: nil,
			hostsURL: hostsURL,
			keychain: KeychainStore(
				service: "unused-\(UUID())",
				accessGroup: nil
			),
			managedKeyStore: managedKeys,
			credentialMaterialStore: materialStore
		)
		return DeletionFixture(
			rootURL: rootURL,
			hostsURL: hostsURL,
			store: sessionStore,
			materialStore: materialStore,
			managedKeys: managedKeys,
			secrets: secrets
		)
	}

	private func applyRemoteMaterial(
		_ secrets: HostSecrets,
		to hostId: UUID
	) async throws {
		let generation = await store.credentialMaterialStore.currentGeneration(
			for: hostId
		)
		guard let commit = try await store.credentialMaterialStore.applyRemote(
			secrets,
			for: hostId,
			expectedGeneration: generation
		) else {
			return XCTFail("expected a provisional remote commit")
		}
		try store.applyRemoteCredentialSource(commit)
		try await store.credentialMaterialStore.resolveRemoteCommit(
			commit,
			as: .commit
		)
	}

	private func waitForQueuedTransactions(
		_ expectedCount: Int,
		hostId: UUID,
		materialStore: SessionCredentialMaterialStore? = nil
	) async {
		let target = materialStore ?? store.credentialMaterialStore
		for _ in 0 ..< 1_000 {
			if await target
				.waitingTransactionCount(for: hostId) == expectedCount {
				return
			}
			await Task.yield()
		}
		XCTFail("timed out waiting for credential transaction queue")
	}
}

private struct DeletionFixture {
	let rootURL: URL
	let hostsURL: URL
	let store: SessionStore
	let materialStore: SessionCredentialMaterialStore
	let managedKeys: ManagedKeyStore
	let secrets: InMemoryCredentialSecretStore
}

private enum CredentialSecretTestError: Error {
	case injectedFailure
}

final class InMemoryCredentialSecretStore: CredentialSecretStoring,
	@unchecked Sendable {
	private let lock = NSLock()
	private var values: [String: String] = [:]
	private var shouldFailDelete = false
	private var shouldFailDeleteAll = false

	func get(account: String) throws -> String {
		lock.lock()
		defer { lock.unlock() }
		guard let value = values[account] else { throw KeychainError.notFound }
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
		if shouldFailDelete {
			shouldFailDelete = false
			throw CredentialSecretTestError.injectedFailure
		}
		guard values.removeValue(forKey: account) != nil else {
			throw KeychainError.notFound
		}
	}

	func deleteAll(prefix: String) throws {
		lock.lock()
		defer { lock.unlock() }
		if shouldFailDeleteAll {
			shouldFailDeleteAll = false
			throw CredentialSecretTestError.injectedFailure
		}
		values = values.filter { !$0.key.hasPrefix(prefix) }
	}

	func failNextDelete() {
		lock.lock()
		shouldFailDelete = true
		lock.unlock()
	}

	func failNextDeleteAll() {
		lock.lock()
		shouldFailDeleteAll = true
		lock.unlock()
	}

	func contains(prefix: String) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return values.keys.contains { $0.hasPrefix(prefix) }
	}
}
