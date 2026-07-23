import CredentialSyncStore
import CredentialSyncTypes
import KeychainStore
import ManagedKeyStore
import SSHCredentialContract
import XCTest
@testable import CredentialSync
@testable import ServerSyncClient
@testable import SessionStore
@testable import SSHCommandBuilder

private struct CredentialPushCall: Sendable {
    let serverId: String
    let blob: CredentialBlob
}

private final class FakeCredentialBlobClient: CredentialBlobPushing,
    @unchecked Sendable {
    private(set) var pushCredentialCalls: [CredentialPushCall] = []
    var pushCredentialError: Error?

    func pushHostCredentialBlob(
        serverId: String,
        blob: CredentialBlob
    ) async throws -> Int64 {
        if let pushCredentialError { throw pushCredentialError }
        pushCredentialCalls.append(
            CredentialPushCall(serverId: serverId, blob: blob)
        )
        return blob.revision
    }
}

@MainActor
final class HostCredentialSyncEngineTests: XCTestCase {
    private var sessionStore: SessionStore!
    private var client: FakeCredentialBlobClient!
    private var preferences: CredentialSyncPreferencesStore!
    private var temporaryDirectory: URL!
    private var managedKeyStore: ManagedKeyStore!
    private var credentialSecretStore: InMemoryEngineCredentialSecretStore!

    override func setUp() async throws {
        try await super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-credential-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        managedKeyStore = ManagedKeyStore(
            rootURL: temporaryDirectory.appendingPathComponent("managed-keys")
        )
        credentialSecretStore = InMemoryEngineCredentialSecretStore()
        let credentialMaterialStore = SessionCredentialMaterialStore(
            secrets: credentialSecretStore,
            managedKeyStore: managedKeyStore
        )
        sessionStore = SessionStore(
            askpassPath: "/x",
            knownHostsCaterm: "/A",
            knownHostsUser: "/B",
            accessGroup: nil,
            hostsURL: temporaryDirectory.appendingPathComponent("hosts.json"),
            keychain: KeychainStore(
                service: "test-\(UUID().uuidString)",
                accessGroup: nil
            ),
            managedKeyStore: managedKeyStore,
            credentialMaterialStore: credentialMaterialStore
        )
        client = FakeCredentialBlobClient()
        preferences = CredentialSyncPreferencesStore(
            defaults: UserDefaults(
                suiteName: "credential-engine-\(UUID().uuidString)"
            )!
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        try await super.tearDown()
    }

    func testBeginCycleOwnsFullScanFlagUntilCheckpointCommits() async throws {
        preferences.mutate { $0.credentialsNeedFullScan = true }
        let sut = makeEngine()

        let start = try await sut.beginCycle()

        XCTAssertEqual(start, .hostSync(requiresFullSnapshot: true))
        sut.didCommitCheckpoint()
        XCTAssertFalse(preferences.prefs.credentialsNeedFullScan)
    }

    func testCredentialHostIDsReturnDirtyHostsOnlyWhenEnabled() async throws {
        var host = SSHHost(
            name: "dirty",
            hostname: "host.example",
            username: "root",
            credential: .password
        )
        host.credentialMaterialDirty = true
        try await sessionStore.addHost(host)
        let sut = makeEngine()

        preferences.mutate { $0.state = .disabled }
        XCTAssertEqual(sut.credentialHostIDs(), [])

        preferences.mutate { $0.state = .enabled }
        XCTAssertEqual(sut.credentialHostIDs(), [host.id])
    }

    func testApplyRemoteBlobOwnsWaitingForKeyTombstoneTransition() async throws {
        preferences.mutate {
            $0.state = .waitingForKey(observedKeyID: "missing-key")
        }
        let sut = makeEngine()
        let localHostID = UUID()
        let remote = RemoteHost(
            id: "server-host",
            name: "host",
            hostname: "host.example",
            port: 22,
            username: "root",
            authType: "password",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        try await sut.applyRemoteBlob(
            localHostId: localHostID,
            remote: remote,
            blob: CredentialBlob(
                state: .tombstone,
                revision: 7,
                keyID: nil
            )
        )

        XCTAssertEqual(
            preferences.prefs.state,
            .pausedByRemote(seenTombstoneRevision: 7)
        )
        XCTAssertNil(preferences.prefs.lastAppliedRevision[localHostID])
    }

    func testBeginCycleCompletesPendingDestructiveDeletion() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .password
        )
        try await sessionStore.addHost(host)
        preferences.mutate {
            $0.deleteCredentialsFromCloudInProgress = DeletionProgress(
                pendingLocalHostIds: [host.id]
            )
        }
        let sut = makeEngine()

        let start = try await sut.beginCycle()

        XCTAssertEqual(start, .handledDestructiveDeletion)
        XCTAssertEqual(client.pushCredentialCalls.count, 1)
        XCTAssertEqual(client.pushCredentialCalls[0].serverId, "server-host")
        XCTAssertEqual(client.pushCredentialCalls[0].blob.state, .tombstone)
        XCTAssertNil(preferences.prefs.deleteCredentialsFromCloudInProgress)
        XCTAssertTrue(preferences.prefs.cloudCredentialsCleared)
    }

    func testLocalCredentialChangeDuringDeletionClearsDirtyAndSuppressesSync() async throws {
        var host = SSHHost(
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .password
        )
        host.credentialMaterialDirty = true
        try await sessionStore.addHost(host)
        preferences.mutate {
            $0.deleteCredentialsFromCloudInProgress = DeletionProgress(
                pendingLocalHostIds: [host.id]
            )
        }
        let sut = makeEngine()

		let shouldSync = await sut.handleLocalCredentialChange(hostId: host.id)
		XCTAssertFalse(shouldSync)
        XCTAssertFalse(sessionStore.hosts[0].credentialMaterialDirty)
    }

    func testPushWithoutServerIDKeepsDirtyForRetry() async throws {
        var host = SSHHost(
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .password
        )
        host.credentialMaterialDirty = true
        try await sessionStore.addHost(host)
        preferences.mutate { $0.state = .enabled }
        let materialStore = InMemoryCredentialMaterialStore(
            snapshotError: TestCredentialError.materialReadFailed
        )
        let sut = makeEngine(materialStore: materialStore)

        try await sut.pushLocalCredential(hostId: host.id)

        let snapshotCount = await materialStore.snapshotCount()
        XCTAssertTrue(sessionStore.hosts[0].credentialMaterialDirty)
        XCTAssertTrue(client.pushCredentialCalls.isEmpty)
        XCTAssertEqual(snapshotCount, 0)
    }

    func testPushForDeletedHostDoesNotReadCredentialMaterial() async throws {
        preferences.mutate { $0.state = .enabled }
        let materialStore = InMemoryCredentialMaterialStore(
            snapshotError: TestCredentialError.materialReadFailed
        )
        let sut = makeEngine(materialStore: materialStore)

        try await sut.pushLocalCredential(hostId: UUID())

        let snapshotCount = await materialStore.snapshotCount()
        XCTAssertTrue(client.pushCredentialCalls.isEmpty)
        XCTAssertEqual(snapshotCount, 0)
    }

    func testPushWithoutEncryptionKeyDoesNotReadCredentialMaterial() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .password,
            credentialMaterialDirty: true
        )
        try await sessionStore.addHost(host)
        preferences.mutate { $0.state = .enabled }
        let materialStore = InMemoryCredentialMaterialStore(
            snapshotError: TestCredentialError.materialReadFailed
        )
        let sut = makeEngine(
            materialWorker: MissingKeyMaterialWorker(),
            materialStore: materialStore
        )

        try await sut.pushLocalCredential(hostId: host.id)

        let snapshotCount = await materialStore.snapshotCount()
        XCTAssertTrue(sessionStore.hosts[0].credentialMaterialDirty)
        XCTAssertTrue(client.pushCredentialCalls.isEmpty)
        XCTAssertEqual(snapshotCount, 0)
    }

    func testBackgroundPushUsesNonInteractiveCredentialRead() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .password,
            credentialMaterialDirty: true
        )
        try await sessionStore.addHost(host)
        preferences.mutate { $0.state = .enabled }
        credentialSecretStore.set(
            account: SSHCredentialContract.account(
                hostID: host.id,
                kind: .password
            ),
            secret: "secret"
        )
        let sut = makeEngine(materialWorker: StubCredentialMaterialWorker())

        try await sut.pushLocalCredential(hostId: host.id)

        let interactions = credentialSecretStore.readInteractions()
        XCTAssertEqual(interactions, [.nonInteractive])
        XCTAssertEqual(client.pushCredentialCalls.count, 1)
        XCTAssertFalse(sessionStore.hosts[0].credentialMaterialDirty)
    }

    func testNonInteractiveCredentialDenialKeepsDirtyForRetry() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .password,
            credentialMaterialDirty: true
        )
        try await sessionStore.addHost(host)
        preferences.mutate { $0.state = .enabled }
        credentialSecretStore.failReads(with: KeychainError.interactionNotAllowed)
        let sut = makeEngine(materialWorker: StubCredentialMaterialWorker())

        do {
            try await sut.pushLocalCredential(hostId: host.id)
            XCTFail("expected non-interactive credential denial")
        } catch KeychainError.interactionNotAllowed {
            // The sync scheduler retries the still-dirty host later.
        }

        let interactions = credentialSecretStore.readInteractions()
        XCTAssertEqual(interactions, [.nonInteractive])
        XCTAssertTrue(client.pushCredentialCalls.isEmpty)
        XCTAssertTrue(sessionStore.hosts[0].credentialMaterialDirty)
        XCTAssertNil(preferences.prefs.lastAppliedRevision[host.id])
    }

    func testPasswordPushExcludesStaleManagedPrivateKey() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .password,
            credentialMaterialDirty: true
        )
        try await sessionStore.addHost(host)
        _ = try await managedKeyStore.write(
            hostId: host.id,
            bytes: Data("stale-key".utf8)
        )
        preferences.mutate { $0.state = .enabled }
        let worker = CapturingCredentialMaterialWorker()
        let sut = makeEngine(materialWorker: worker)

        try await sut.pushLocalCredential(hostId: host.id)

        let capturedRequest = await worker.lastRequest()
        let capturedMaterial = await worker.lastMaterial()
        let request = try XCTUnwrap(capturedRequest)
        let material = try XCTUnwrap(capturedMaterial)
        XCTAssertNil(material.managedPrivateKey)
        XCTAssertNil(request.fallbackPrivateKeyPath)
        XCTAssertEqual(client.pushCredentialCalls.count, 1)
    }

    func testPushRejectsHostSourceCapturedBeforeQueuedKeyEdit() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .password,
            credentialMaterialDirty: true
        )
        try await sessionStore.addHost(host)
        preferences.mutate { $0.state = .enabled }
        let localCommit = try await sessionStore.credentialMaterialStore
            .applyLocal(
                HostSecrets(privateKeyBytes: Data("new-key".utf8)),
                source: .keyFile(path: "", hasPassphrase: false),
                for: host.id
            )
        let sut = makeEngine(materialWorker: StubCredentialMaterialWorker())
        let push = Task {
            try await sut.pushLocalCredential(hostId: host.id)
        }
        await waitForCredentialQueue(1, hostId: host.id)

        guard case let .keyFile(path, hasPassphrase) = localCommit.source else {
            return XCTFail("expected a managed key credential source")
        }
        try await sessionStore.setCredentialOnly(
            .keyFile(keyPath: path, hasPassphrase: hasPassphrase),
            for: host.id
        )
        await sessionStore.credentialMaterialStore
            .finalizeLocalCommit(localCommit)
        try await push.value

        XCTAssertTrue(client.pushCredentialCalls.isEmpty)
        XCTAssertTrue(sessionStore.hosts[0].credentialMaterialDirty)
        XCTAssertNil(preferences.prefs.lastAppliedRevision[host.id])
    }

    func testEditWhilePushIsSuspendedWaitsForCommittedRevision() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .password,
            credentialMaterialDirty: true
        )
        try await sessionStore.addHost(host)
        preferences.mutate { $0.state = .enabled }
        let gate = AsyncOperationGate()
        let gatedClient = GatedCredentialClient(gate: gate)
        let worker = StubCredentialMaterialWorker()
        let sut = makeEngine(
            client: gatedClient,
            materialWorker: worker
        )

        let push = Task {
            try await sut.pushLocalCredential(hostId: host.id)
        }
        await gate.waitUntilPushStarts()

        let edit = Task {
            try await sessionStore.setHostCredentialMaterial(
                secrets: HostSecrets(password: Data("new-password".utf8)),
                credentialSource: .password,
                for: host.id
            )
        }
        await waitForCredentialQueue(1, hostId: host.id)
        let generationDuringPush = await sessionStore.credentialMaterialStore
            .currentGeneration(for: host.id)
        XCTAssertEqual(generationDuringPush, 0)

        await gate.resumePush()
        try await push.value
        try await edit.value

        XCTAssertTrue(
            sessionStore.hosts[0].credentialMaterialDirty,
            "the edit after a committed push must remain dirty"
        )
        XCTAssertEqual(preferences.prefs.lastAppliedRevision[host.id], 1)
        XCTAssertTrue(preferences.prefs.hostsWithCloudPayload.contains(host.id))
        let generationAfterEdit = await sessionStore.credentialMaterialStore
            .currentGeneration(for: host.id)
        XCTAssertEqual(generationAfterEdit, 1)
    }

    func testAccountResetWhilePushIsSuspendedDoesNotRestorePreferences() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .password,
            credentialMaterialDirty: true
        )
        try await sessionStore.addHost(host)
        preferences.mutate { $0.state = .enabled }
        let gate = AsyncOperationGate()
        let materialStore = InMemoryCredentialMaterialStore()
        let sut = makeEngine(
            client: GatedCredentialClient(gate: gate),
            materialWorker: StubCredentialMaterialWorker(),
            materialStore: materialStore
        )
        let push = Task {
            try await sut.pushLocalCredential(hostId: host.id)
        }
        await gate.waitUntilPushStarts()

        preferences.mutate {
            $0.state = .disabled
            $0.lastAppliedRevision = [:]
            $0.hostsWithCloudPayload = []
            $0.cloudCredentialsCleared = false
        }
        await materialStore.recordLocalMutation(for: host.id)
        await gate.resumePush()
        try await push.value

        XCTAssertEqual(preferences.prefs.state, .disabled)
        XCTAssertNil(preferences.prefs.lastAppliedRevision[host.id])
        XCTAssertFalse(preferences.prefs.hostsWithCloudPayload.contains(host.id))
        XCTAssertFalse(preferences.prefs.cloudCredentialsCleared)
        XCTAssertTrue(sessionStore.hosts[0].credentialMaterialDirty)
    }

    func testLocalEditWhilePullDecryptsRejectsLateRemoteMaterial() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .agent,
            credentialMaterialDirty: true
        )
        try await sessionStore.addHost(host)
        preferences.mutate { $0.state = .enabled }
        let gate = AsyncOperationGate()
        let worker = GatedPullMaterialWorker(gate: gate)
        let materialStore = InMemoryCredentialMaterialStore()
        let sut = makeEngine(
            materialWorker: worker,
            materialStore: materialStore
        )

        let pull = Task {
            try await sut.applyRemoteBlob(
                localHostId: host.id,
                remote: makeRemoteHost(),
                blob: makePayloadBlob()
            )
        }
        await gate.waitUntilPushStarts()

        await materialStore.recordLocalMutation(for: host.id)
        await gate.resumePush()
        try await pull.value

        XCTAssertEqual(sessionStore.hosts[0].credential, .agent)
        XCTAssertTrue(sessionStore.hosts[0].credentialMaterialDirty)
        XCTAssertNil(preferences.prefs.lastAppliedRevision[host.id])
    }

    func testRemoteMaterialCommitAppliesStrongCredentialSource() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .agent
        )
        try await sessionStore.addHost(host)
        preferences.mutate { $0.state = .enabled }
        let materialStore = InMemoryCredentialMaterialStore()
        let sut = makeEngine(
            materialWorker: StubCredentialMaterialWorker(
                remoteMaterial: HostSecrets(password: Data("remote".utf8))
            ),
            materialStore: materialStore
        )

        try await sut.applyRemoteBlob(
            localHostId: host.id,
            remote: makeRemoteHost(),
            blob: makePayloadBlob()
        )

        XCTAssertEqual(sessionStore.hosts[0].credential, .password)
        XCTAssertEqual(preferences.prefs.lastAppliedRevision[host.id], 1)
        XCTAssertTrue(preferences.prefs.hostsWithCloudPayload.contains(host.id))
    }

    func testDisablingSyncWhilePullDecryptsRejectsLateRemoteMaterial() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .agent
        )
        try await sessionStore.addHost(host)
        preferences.mutate { $0.state = .enabled }
        let gate = AsyncOperationGate()
        let materialStore = InMemoryCredentialMaterialStore()
        let sut = makeEngine(
            materialWorker: GatedPullMaterialWorker(gate: gate),
            materialStore: materialStore
        )

        let pull = Task {
            try await sut.applyRemoteBlob(
                localHostId: host.id,
                remote: makeRemoteHost(),
                blob: makePayloadBlob()
            )
        }
        await gate.waitUntilPushStarts()

        preferences.mutate { $0.state = .disabled }
        await gate.resumePush()
        try await pull.value

        XCTAssertEqual(sessionStore.hosts[0].credential, .agent)
        XCTAssertNil(preferences.prefs.lastAppliedRevision[host.id])
    }

    func testDeletingHostWhilePullDecryptsDiscardsLateRemoteMaterial() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .agent
        )
        try await sessionStore.addHost(host)
        preferences.mutate { $0.state = .enabled }
        let gate = AsyncOperationGate()
        let materialStore = InMemoryCredentialMaterialStore()
        let sut = makeEngine(
            materialWorker: GatedPullMaterialWorker(gate: gate),
            materialStore: materialStore
        )

        let pull = Task {
            try await sut.applyRemoteBlob(
                localHostId: host.id,
                remote: makeRemoteHost(),
                blob: makePayloadBlob()
            )
        }
        await gate.waitUntilPushStarts()

        try await sessionStore.deleteHost(id: host.id)
        await gate.resumePush()
        try await pull.value

        XCTAssertTrue(sessionStore.hosts.isEmpty)
        XCTAssertNil(preferences.prefs.lastAppliedRevision[host.id])
    }

    func testMissingKeyWaitsForLocalCommitAndKeepsSyncEnabled() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .agent
        )
        try await sessionStore.addHost(host)
        preferences.mutate { $0.state = .enabled }
        let localCommit = try await sessionStore.credentialMaterialStore
            .applyLocal(
                HostSecrets(),
                source: .agent,
                for: host.id
            )
        let sut = makeEngine(materialWorker: MissingKeyMaterialWorker())
        let pull = Task {
            try await sut.applyRemoteBlob(
                localHostId: host.id,
                remote: makeRemoteHost(),
                blob: makePayloadBlob()
            )
        }
        await waitForCredentialQueue(1, hostId: host.id)

        await sessionStore.credentialMaterialStore
            .finalizeLocalCommit(localCommit)
        try await pull.value

        XCTAssertEqual(preferences.prefs.state, .enabled)
    }

    func testDisablingSyncAfterProvisionalWriteRollsBackRemoteMaterial() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .agent
        )
        try await sessionStore.addHost(host)
        preferences.mutate { $0.state = .enabled }
        let gate = AsyncOperationGate()
        let materialStore = InMemoryCredentialMaterialStore(
            generationGate: gate,
            gatedGenerationCall: 3
        )
        let sut = makeEngine(
            materialWorker: StubCredentialMaterialWorker(
                remoteMaterial: HostSecrets(password: Data("remote".utf8))
            ),
            materialStore: materialStore
        )

        let pull = Task {
            try await sut.applyRemoteBlob(
                localHostId: host.id,
                remote: makeRemoteHost(),
                blob: makePayloadBlob()
            )
        }
        await gate.waitUntilPushStarts()

        preferences.mutate { $0.state = .disabled }
        await gate.resumePush()
        try await pull.value

        let rollbackCount = await materialStore.rollbackCount()
        let finalizeCount = await materialStore.finalizeCount()
        XCTAssertEqual(sessionStore.hosts[0].credential, .agent)
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertEqual(finalizeCount, 0)
        XCTAssertNil(preferences.prefs.lastAppliedRevision[host.id])
    }

    func testDeletingHostAfterProvisionalWriteDiscardsRemoteMaterial() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .agent
        )
        try await sessionStore.addHost(host)
        preferences.mutate { $0.state = .enabled }
        let gate = AsyncOperationGate()
        let materialStore = InMemoryCredentialMaterialStore(
            generationGate: gate,
            gatedGenerationCall: 3
        )
        let sut = makeEngine(
            materialWorker: StubCredentialMaterialWorker(
                remoteMaterial: HostSecrets(password: Data("remote".utf8))
            ),
            materialStore: materialStore
        )

        let pull = Task {
            try await sut.applyRemoteBlob(
                localHostId: host.id,
                remote: makeRemoteHost(),
                blob: makePayloadBlob()
            )
        }
        await gate.waitUntilPushStarts()

        try await sessionStore.deleteHost(id: host.id)
        await gate.resumePush()
        try await pull.value

        let discardCount = await materialStore.discardCount()
        let finalizeCount = await materialStore.finalizeCount()
        XCTAssertTrue(sessionStore.hosts.isEmpty)
        XCTAssertEqual(discardCount, 1)
        XCTAssertEqual(finalizeCount, 0)
        XCTAssertNil(preferences.prefs.lastAppliedRevision[host.id])
    }

    func testCancellationAfterProvisionalWriteRollsBackRemoteMaterial() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .agent
        )
        try await sessionStore.addHost(host)
        preferences.mutate { $0.state = .enabled }
        let gate = AsyncOperationGate()
        let materialStore = InMemoryCredentialMaterialStore(
            generationGate: gate,
            gatedGenerationCall: 3
        )
        let sut = makeEngine(
            materialWorker: StubCredentialMaterialWorker(
                remoteMaterial: HostSecrets(password: Data("remote".utf8))
            ),
            materialStore: materialStore
        )

        let pull = Task {
            try await sut.applyRemoteBlob(
                localHostId: host.id,
                remote: makeRemoteHost(),
                blob: makePayloadBlob()
            )
        }
        await gate.waitUntilPushStarts()

        pull.cancel()
        await gate.resumePush()
        do {
            try await pull.value
            XCTFail("cancelled pull must not finalize provisional material")
        } catch is CancellationError {
            // Expected.
        }

        let rollbackCount = await materialStore.rollbackCount()
        let finalizeCount = await materialStore.finalizeCount()
        XCTAssertEqual(sessionStore.hosts[0].credential, .agent)
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertEqual(finalizeCount, 0)
        XCTAssertNil(preferences.prefs.lastAppliedRevision[host.id])
    }

    func testDestructiveDeletionPushFailurePropagatesAndKeepsProgress() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .password
        )
        try await sessionStore.addHost(host)
        preferences.mutate {
            $0.deleteCredentialsFromCloudInProgress = DeletionProgress(
                pendingLocalHostIds: [host.id]
            )
        }
        client.pushCredentialError = TestCredentialError.pushFailed
        let sut = makeEngine()

        do {
            _ = try await sut.beginCycle()
            XCTFail("deletion push failure must propagate")
        } catch TestCredentialError.pushFailed {
            // Expected.
        }

        XCTAssertEqual(
            preferences.prefs.deleteCredentialsFromCloudInProgress,
            DeletionProgress(pendingLocalHostIds: [host.id])
        )
        XCTAssertFalse(preferences.prefs.cloudCredentialsCleared)
    }

    func testCancellationAfterNonCooperativeTombstoneStopsBeforeNextHost() async throws {
        let hostA = SSHHost(
            serverId: "server-a",
            name: "A",
            hostname: "a.example",
            username: "root",
            credential: .password
        )
        let hostB = SSHHost(
            serverId: "server-b",
            name: "B",
            hostname: "b.example",
            username: "root",
            credential: .password
        )
        try await sessionStore.addHost(hostA)
        try await sessionStore.addHost(hostB)
        preferences.mutate {
            $0.deleteCredentialsFromCloudInProgress = DeletionProgress(
                pendingLocalHostIds: [hostA.id, hostB.id]
            )
        }
        let gate = AsyncOperationGate()
        let nonCooperativeClient = FirstPushGatedCredentialClient(gate: gate)
        let sut = makeEngine(client: nonCooperativeClient)

        let deletion = Task { try await sut.beginCycle() }
        await gate.waitUntilPushStarts()
        deletion.cancel()
        await gate.resumePush()

        do {
            _ = try await deletion.value
            XCTFail("cancelled deletion must not continue to the next host")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(nonCooperativeClient.callCount, 1)
        XCTAssertEqual(
            preferences.prefs.deleteCredentialsFromCloudInProgress,
            DeletionProgress(pendingLocalHostIds: [hostA.id, hostB.id])
        )
        XCTAssertNil(preferences.prefs.lastAppliedRevision[hostA.id])
        XCTAssertNil(preferences.prefs.lastAppliedRevision[hostB.id])
    }

    func testAccountResetWhileTombstoneIsSuspendedDoesNotRestoreProgress() async throws {
        let host = SSHHost(
            serverId: "server-host",
            name: "host",
            hostname: "host.example",
            username: "root",
            credential: .password
        )
        try await sessionStore.addHost(host)
        preferences.mutate {
            $0.deleteCredentialsFromCloudInProgress = DeletionProgress(
                pendingLocalHostIds: [host.id]
            )
        }
        let gate = AsyncOperationGate()
        let materialStore = InMemoryCredentialMaterialStore()
        let sut = makeEngine(
            client: GatedCredentialClient(gate: gate),
            materialStore: materialStore
        )
        let deletion = Task { try await sut.beginCycle() }
        await gate.waitUntilPushStarts()

        preferences.mutate {
            $0.state = .disabled
            $0.lastAppliedRevision = [:]
            $0.hostsWithCloudPayload = []
            $0.deleteCredentialsFromCloudInProgress = nil
            $0.cloudCredentialsCleared = false
        }
        await materialStore.recordLocalMutation(for: host.id)
        await gate.resumePush()
        _ = try await deletion.value

        XCTAssertNil(preferences.prefs.deleteCredentialsFromCloudInProgress)
        XCTAssertNil(preferences.prefs.lastAppliedRevision[host.id])
        XCTAssertFalse(preferences.prefs.hostsWithCloudPayload.contains(host.id))
        XCTAssertFalse(preferences.prefs.cloudCredentialsCleared)
    }

    private func makeRemoteHost() -> RemoteHost {
        RemoteHost(
            id: "server-host",
            name: "host",
            hostname: "host.example",
            port: 22,
            username: "root",
            authType: "password",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func makePayloadBlob() -> CredentialBlob {
        CredentialBlob(
            state: .payload,
            revision: 1,
            keyID: "test-key"
        )
    }

    private func waitForCredentialQueue(
        _ expectedCount: Int,
        hostId: UUID
    ) async {
        for _ in 0 ..< 1_000 {
            if await sessionStore.credentialMaterialStore
                .waitingTransactionCount(for: hostId) == expectedCount {
                return
            }
            await Task.yield()
        }
        XCTFail("timed out waiting for credential transaction queue")
    }

    private func makeEngine(
        client overrideClient: (any CredentialBlobPushing)? = nil,
        materialWorker: (any HostCredentialMaterialWorking)? = nil,
        materialStore: (any HostCredentialMaterialStoring)? = nil
    ) -> HostCredentialSyncEngine {
        HostCredentialSyncEngine(
            client: overrideClient ?? client,
            sessionStore: sessionStore,
            preferences: preferences,
            masterKeyStore: KeychainSyncMasterKeyStore(
                service: "test-\(UUID().uuidString)",
                synchronizable: false
            ),
            materialWorker: materialWorker,
            materialStore: materialStore
        )
    }
}

private enum TestCredentialError: Error {
    case pushFailed
    case materialReadFailed
}

private final class InMemoryEngineCredentialSecretStore:
    CredentialSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var interactions: [KeychainReadInteraction] = []
    private var getError: Error?

    func get(
        account: String,
        interaction: KeychainReadInteraction
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        interactions.append(interaction)
        if let getError { throw getError }
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
        guard values.removeValue(forKey: account) != nil else {
            throw KeychainError.notFound
        }
    }

    func deleteAll(prefix: String) {
        lock.lock()
        values = values.filter { !$0.key.hasPrefix(prefix) }
        lock.unlock()
    }

    func readInteractions() -> [KeychainReadInteraction] {
        lock.lock()
        defer { lock.unlock() }
        return interactions
    }

    func failReads(with error: Error) {
        lock.lock()
        getError = error
        lock.unlock()
    }
}

private actor StubCredentialMaterialWorker: HostCredentialMaterialWorking {
    private let remoteMaterial: HostSecrets

    init(remoteMaterial: HostSecrets = HostSecrets()) {
        self.remoteMaterial = remoteMaterial
    }

    func makeEncryptedBlob(
        from request: LocalCredentialEncryptionRequest,
        loadMaterial: @escaping CredentialMaterialLoader
    ) async throws -> EncryptedLocalCredentialBlob? {
        let material = try await loadMaterial()
        return EncryptedLocalCredentialBlob(
            blob: CredentialBlob(
                state: .payload,
                revision: request.revision,
                keyID: "test-key"
            ),
            materialGeneration: material.generation
        )
    }

    func decrypt(
        serverId: String,
        blob: CredentialBlob
    ) -> RemoteCredentialMaterialResult {
        .material(remoteMaterial)
    }
}

private actor CapturingCredentialMaterialWorker: HostCredentialMaterialWorking {
    private var request: LocalCredentialEncryptionRequest?
    private var material: StoredCredentialMaterialSnapshot?

    func makeEncryptedBlob(
        from request: LocalCredentialEncryptionRequest,
        loadMaterial: @escaping CredentialMaterialLoader
    ) async throws -> EncryptedLocalCredentialBlob? {
        let material = try await loadMaterial()
        self.request = request
        self.material = material
        return EncryptedLocalCredentialBlob(
            blob: CredentialBlob(
                state: .payload,
                revision: request.revision,
                keyID: "test-key"
            ),
            materialGeneration: material.generation
        )
    }

    func decrypt(
        serverId: String,
        blob: CredentialBlob
    ) -> RemoteCredentialMaterialResult {
        .material(HostSecrets())
    }

    func lastRequest() -> LocalCredentialEncryptionRequest? { request }

    func lastMaterial() -> StoredCredentialMaterialSnapshot? { material }
}

private actor GatedPullMaterialWorker: HostCredentialMaterialWorking {
    let gate: AsyncOperationGate

    init(gate: AsyncOperationGate) {
        self.gate = gate
    }

    func makeEncryptedBlob(
        from request: LocalCredentialEncryptionRequest,
        loadMaterial: @escaping CredentialMaterialLoader
    ) -> EncryptedLocalCredentialBlob? {
        nil
    }

    func decrypt(
        serverId: String,
        blob: CredentialBlob
    ) async -> RemoteCredentialMaterialResult {
        await gate.suspendPush()
        return .material(HostSecrets(password: Data("remote".utf8)))
    }
}

private actor MissingKeyMaterialWorker: HostCredentialMaterialWorking {
    func makeEncryptedBlob(
        from request: LocalCredentialEncryptionRequest,
        loadMaterial: @escaping CredentialMaterialLoader
    ) -> EncryptedLocalCredentialBlob? {
        nil
    }

    func decrypt(
        serverId: String,
        blob: CredentialBlob
    ) -> RemoteCredentialMaterialResult {
        .missingKey(keyID: blob.keyID)
    }
}

private actor InMemoryCredentialMaterialStore: HostCredentialMaterialStoring {
    private var generations: [UUID: UInt64] = [:]
    private let generationGate: AsyncOperationGate?
    private let gatedGenerationCall: Int?
    private var generationCallCount = 0
    private var finalizedCommits = 0
    private var rolledBackCommits = 0
    private var discardedCommits = 0
    private let snapshotError: Error?
    private var snapshots = 0

    init(
        generationGate: AsyncOperationGate? = nil,
        gatedGenerationCall: Int? = nil,
        snapshotError: Error? = nil
    ) {
        self.generationGate = generationGate
        self.gatedGenerationCall = gatedGenerationCall
        self.snapshotError = snapshotError
    }

    func recordLocalMutation(for hostId: UUID) {
        generations[hostId, default: 0] &+= 1
    }

    func snapshot(
        for hostId: UUID,
        selecting selection: CredentialMaterialSelection,
        interaction: KeychainReadInteraction
    ) throws -> StoredCredentialMaterialSnapshot {
        snapshots += 1
        if let snapshotError { throw snapshotError }
        return StoredCredentialMaterialSnapshot(
            generation: generations[hostId, default: 0],
            password: nil,
            passphrase: nil,
            managedPrivateKey: nil
        )
    }

    func snapshotCount() -> Int { snapshots }

    func currentGeneration(for hostId: UUID) async -> UInt64 {
        generationCallCount += 1
        if generationCallCount == gatedGenerationCall,
           let generationGate {
            await generationGate.suspendPush()
        }
        return generations[hostId, default: 0]
    }

    func beginGenerationValidation(
        for hostId: UUID,
        expectedGeneration: UInt64
    ) -> CredentialGenerationValidation? {
        guard generations[hostId, default: 0] == expectedGeneration else {
            return nil
        }
        return CredentialGenerationValidation(id: UUID(), hostId: hostId)
    }

    func finishGenerationValidation(
        _ validation: CredentialGenerationValidation
    ) {}

    func applyRemote(
        _ secrets: HostSecrets,
        for hostId: UUID,
        expectedGeneration: UInt64
    ) -> RemoteCredentialMaterialCommit? {
        guard generations[hostId, default: 0] == expectedGeneration else {
            return nil
        }
        return RemoteCredentialMaterialCommit(
            source: secrets.password == nil ? .unchanged : .password,
            id: UUID(),
            hostId: hostId
        )
    }

    func resolveRemoteCommit(
        _ commit: RemoteCredentialMaterialCommit,
        as disposition: RemoteCredentialCommitDisposition
    ) throws {
        switch disposition {
        case .commit:
            generations[commit.hostId, default: 0] &+= 1
            finalizedCommits += 1
        case .rollback:
            rolledBackCommits += 1
        case .discard:
            discardedCommits += 1
        }
    }

    func finalizeCount() -> Int { finalizedCommits }

    func rollbackCount() -> Int { rolledBackCommits }

    func discardCount() -> Int { discardedCommits }
}

private actor AsyncOperationGate {
    private var pushStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func suspendPush() async {
        pushStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilPushStarts() async {
        guard !pushStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumePush() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private final class GatedCredentialClient: CredentialBlobPushing, @unchecked Sendable {
    private let gate: AsyncOperationGate

    init(gate: AsyncOperationGate) {
        self.gate = gate
    }

    func pushHostCredentialBlob(
        serverId: String,
        blob: CredentialBlob
    ) async throws -> Int64 {
        await gate.suspendPush()
        return blob.revision
    }
}

private final class FirstPushGatedCredentialClient: CredentialBlobPushing,
    @unchecked Sendable {
    private let gate: AsyncOperationGate
    private(set) var callCount = 0

    init(gate: AsyncOperationGate) {
        self.gate = gate
    }

    func pushHostCredentialBlob(
        serverId: String,
        blob: CredentialBlob
    ) async throws -> Int64 {
        callCount += 1
        if callCount == 1 {
            await gate.suspendPush()
        }
        return blob.revision
    }
}
