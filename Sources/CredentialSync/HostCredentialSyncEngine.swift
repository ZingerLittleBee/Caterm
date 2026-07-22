import CredentialSyncStore
import CredentialSyncTypes
import Foundation
import KeychainStore
import os
import ServerSyncClient
import SessionStore

protocol HostCredentialMaterialStoring: Sendable {
    func snapshot(
        for hostId: UUID,
        selecting selection: CredentialMaterialSelection,
        interaction: KeychainReadInteraction
    ) async throws
        -> StoredCredentialMaterialSnapshot
    func currentGeneration(for hostId: UUID) async -> UInt64
    func beginGenerationValidation(
        for hostId: UUID,
        expectedGeneration: UInt64
    ) async throws -> CredentialGenerationValidation?
    func finishGenerationValidation(
        _ validation: CredentialGenerationValidation
    ) async
    func applyRemote(
        _ secrets: HostSecrets,
        for hostId: UUID,
        expectedGeneration: UInt64
    ) async throws -> RemoteCredentialMaterialCommit?
    func resolveRemoteCommit(
        _ commit: RemoteCredentialMaterialCommit,
        as disposition: RemoteCredentialCommitDisposition
    ) async throws
}

extension SessionCredentialMaterialStore: HostCredentialMaterialStoring {}

/// Owns credential-specific state transitions and side effects within a host
/// sync cycle. The surrounding `HostSyncStore` remains responsible for cycle
/// scheduling, metadata reconciliation, and user-visible freshness state.
@MainActor
public final class HostCredentialSyncEngine {
    public enum CycleStart: Equatable {
        case hostSync(requiresFullSnapshot: Bool)
        case handledDestructiveDeletion
    }

    private static let log = Logger(
        subsystem: "com.caterm.app",
        category: "credential-sync"
    )

    private let client: any CredentialBlobPushing
    private let sessionStore: SessionStore
    private let preferences: CredentialSyncPreferencesStore
    private let materialWorker: any HostCredentialMaterialWorking
    private let materialStore: any HostCredentialMaterialStoring

    #if DEBUG
    public private(set) var decryptAndApplyInvocations: [
        (localHostId: UUID, revision: Int64)
    ] = []
    #endif

    public convenience init(
        client: any CredentialBlobPushing,
        sessionStore: SessionStore,
        preferences: CredentialSyncPreferencesStore,
        masterKeyStore: KeychainSyncMasterKeyStore
    ) {
        self.init(
            client: client,
            sessionStore: sessionStore,
            preferences: preferences,
            masterKeyStore: masterKeyStore,
            materialWorker: nil,
            materialStore: nil
        )
    }

    init(
        client: any CredentialBlobPushing,
        sessionStore: SessionStore,
        preferences: CredentialSyncPreferencesStore,
        masterKeyStore: KeychainSyncMasterKeyStore,
        materialWorker: (any HostCredentialMaterialWorking)? = nil,
        materialStore: (any HostCredentialMaterialStoring)? = nil
    ) {
        self.client = client
        self.sessionStore = sessionStore
        self.preferences = preferences
        self.materialStore = materialStore ?? sessionStore.credentialMaterialStore
        self.materialWorker = materialWorker ?? HostCredentialMaterialWorker(
            masterKeyStore: masterKeyStore
        )
    }

    /// Runs the destructive credential-only pipeline when one is pending.
    /// Otherwise returns the credential requirements for a normal host cycle.
    public func beginCycle() async throws -> CycleStart {
        if let progress = preferences.prefs.deleteCredentialsFromCloudInProgress {
            try await runDestructiveDeletion(progress: progress)
            return .handledDestructiveDeletion
        }
        return .hostSync(
            requiresFullSnapshot: preferences.prefs.credentialsNeedFullScan
        )
    }

    /// Returns credential pushes in host order. The host-sync scheduler appends
    /// them after metadata operations so newly-created hosts have server IDs.
    public func credentialHostIDs() -> [UUID] {
        let prefs = preferences.prefs
        guard prefs.deleteCredentialsFromCloudInProgress == nil,
              case .enabled = prefs.state else {
            return []
        }

        return sessionStore.hosts
            .filter(\.credentialMaterialDirty)
            .map(\.id)
    }

    /// Clears the full-scan request only after the host checkpoint commits.
    public func didCommitCheckpoint() {
        guard preferences.prefs.credentialsNeedFullScan else { return }
        preferences.mutate { $0.credentialsNeedFullScan = false }
    }

    /// Returns whether the normal auto-sync path should be scheduled.
    /// During destructive deletion, a fresh local edit must not repopulate the
    /// cloud credential that the deletion pipeline is tombstoning.
    public func handleLocalCredentialChange(hostId: UUID) -> Bool {
        guard preferences.prefs.deleteCredentialsFromCloudInProgress != nil else {
            return true
        }
        do {
            try sessionStore.clearCredentialMaterialDirty(hostId)
        } catch {
            let errorDescription = String(describing: error)
            Self.log.error(
                "dirty clear failed: \(hostId, privacy: .public): \(errorDescription, privacy: .public)"
            )
        }
        return false
    }

    /// Applies a remote credential blob through the persisted credential state
    /// machine. Stale revisions are ignored without mutating the high-water mark.
    public func applyRemoteBlob(
        localHostId: UUID,
        remote: RemoteHost,
        blob: CredentialBlob
    ) async throws {
        let lastApplied = preferences.prefs.lastAppliedRevision[localHostId] ?? 0
        guard blob.revision > lastApplied else { return }

        switch preferences.prefs.state {
        case .disabled:
            // Re-enabling must be able to replay this blob.
            return

        case .pausedByRemote(let seenTombstoneRevision):
            if blob.state == .payload,
               blob.revision > seenTombstoneRevision {
                preferences.mutate {
                    $0.state = .pausedByRemote(
                        seenTombstoneRevision: blob.revision
                    )
                }
            }

        case .waitingForKey:
            switch blob.state {
            case .payload:
                preferences.mutate {
                    $0.state = .waitingForKey(observedKeyID: blob.keyID)
                }
            case .tombstone:
                preferences.mutate {
                    $0.state = .pausedByRemote(
                        seenTombstoneRevision: blob.revision
                    )
                }
            case .none:
                break
            }

        case .enabled:
            switch blob.state {
            case .tombstone:
                preferences.mutate {
                    $0.state = .pausedByRemote(
                        seenTombstoneRevision: blob.revision
                    )
                    $0.lastAppliedRevision[localHostId] = blob.revision
                    $0.hostsWithCloudPayload.remove(localHostId)
                }
            case .none:
                preferences.mutate {
                    $0.lastAppliedRevision[localHostId] = blob.revision
                }
            case .payload:
                try await decryptAndApply(
                    localHostId: localHostId,
                    remote: remote,
                    blob: blob
                )
            }
        }
    }

    /// Encrypts and pushes the current local credential material for one host.
    /// Missing prerequisites are retryable no-ops and keep the dirty bit set.
    public func pushLocalCredential(hostId: UUID) async throws {
        guard case .enabled = preferences.prefs.state else { return }
        guard let host = sessionStore.hosts.first(where: { $0.id == hostId }) else {
            return
        }
        guard let serverId = host.serverId else { return }
        let nextRevision =
            (preferences.prefs.lastAppliedRevision[hostId] ?? 0) + 1
        let selection: CredentialMaterialSelection
        let fallbackPrivateKeyPath: String?
        switch host.credential {
        case .password:
            selection = .password
            fallbackPrivateKeyPath = nil
        case let .keyFile(path, hasPassphrase):
            selection = hasPassphrase
                ? [.passphrase, .managedPrivateKey]
                : .managedPrivateKey
            let managedPath = sessionStore.managedKeyPath(for: hostId)
            fallbackPrivateKeyPath = path == managedPath ? nil : path
        case .agent:
            selection = []
            fallbackPrivateKeyPath = nil
        }
        let request = LocalCredentialEncryptionRequest(
            serverId: serverId,
            fallbackPrivateKeyPath: fallbackPrivateKeyPath,
            revision: nextRevision
        )
        guard let encrypted = try await materialWorker.makeEncryptedBlob(
            from: request,
            loadMaterial: { [materialStore] in
                try await materialStore.snapshot(
                    for: hostId,
                    selecting: selection,
                    interaction: .nonInteractive
                )
            }
        ) else { return }
        guard let validation = try await materialStore.beginGenerationValidation(
            for: hostId,
            expectedGeneration: encrypted.materialGeneration
        ) else { return }
        do {
            try Task.checkCancellation()
            guard case .enabled = preferences.prefs.state,
                  let currentHost = sessionStore.hosts.first(where: {
                      $0.id == hostId
                  }),
                  currentHost.serverId == serverId,
                  currentHost.credential == host.credential,
                  currentHost.credentialMaterialDirty else {
                await materialStore.finishGenerationValidation(validation)
                return
            }
            let pushedRevision = try await client.pushHostCredentialBlob(
                serverId: serverId,
                blob: encrypted.blob
            )
            try Task.checkCancellation()
            guard case .enabled = preferences.prefs.state else {
                await materialStore.finishGenerationValidation(validation)
                return
            }
            preferences.mutate {
                $0.lastAppliedRevision[hostId] = pushedRevision
                $0.hostsWithCloudPayload.insert(hostId)
                $0.cloudCredentialsCleared = false
            }
            try sessionStore.clearCredentialMaterialDirty(hostId)
        } catch {
            await materialStore.finishGenerationValidation(validation)
            throw error
        }
        await materialStore.finishGenerationValidation(validation)
    }

    private func runDestructiveDeletion(
        progress: DeletionProgress
    ) async throws {
        var remaining = progress.pendingLocalHostIds
        for localHostId in progress.pendingLocalHostIds {
            try Task.checkCancellation()
            guard let host = sessionStore.hosts.first(where: {
                $0.id == localHostId
            }), let serverId = host.serverId else {
                remaining.removeAll { $0 == localHostId }
                persistDeletionProgress(remaining)
                continue
            }
            let generationBeforePush = await materialStore.currentGeneration(
                for: localHostId
            )
            try Task.checkCancellation()
            guard preferences.prefs.deleteCredentialsFromCloudInProgress?
                .pendingLocalHostIds.contains(localHostId) == true else {
                return
            }

            let nextRevision =
                (preferences.prefs.lastAppliedRevision[localHostId] ?? 0) + 1
            let tombstone = CredentialBlob(
                state: .tombstone,
                revision: nextRevision,
                keyID: nil
            )
            _ = try await client.pushHostCredentialBlob(
                serverId: serverId,
                blob: tombstone
            )
            guard let validation = try await materialStore
                .beginGenerationValidation(
                    for: localHostId,
                    expectedGeneration: generationBeforePush
                ) else {
                return
            }
            do {
                try Task.checkCancellation()
                guard let currentProgress = preferences.prefs
                    .deleteCredentialsFromCloudInProgress,
                    currentProgress.pendingLocalHostIds.contains(localHostId) else {
                    await materialStore.finishGenerationValidation(validation)
                    return
                }
                remaining = currentProgress.pendingLocalHostIds
                remaining.removeAll { $0 == localHostId }
                preferences.mutate {
                    $0.lastAppliedRevision[localHostId] = nextRevision
                    $0.hostsWithCloudPayload.remove(localHostId)
                    $0.deleteCredentialsFromCloudInProgress = DeletionProgress(
                        pendingLocalHostIds: remaining
                    )
                }
            } catch {
                await materialStore.finishGenerationValidation(validation)
                throw error
            }
            await materialStore.finishGenerationValidation(validation)
        }

        guard remaining.isEmpty,
              preferences.prefs.deleteCredentialsFromCloudInProgress?
              .pendingLocalHostIds.isEmpty == true else {
            return
        }
        preferences.mutate {
            $0.deleteCredentialsFromCloudInProgress = nil
            $0.cloudCredentialsCleared = true
        }
    }

    private func persistDeletionProgress(_ remaining: [UUID]) {
        preferences.mutate {
            $0.deleteCredentialsFromCloudInProgress = DeletionProgress(
                pendingLocalHostIds: remaining
            )
        }
    }

    private func decryptAndApply(
        localHostId: UUID,
        remote: RemoteHost,
        blob: CredentialBlob
    ) async throws {
        #if DEBUG
        decryptAndApplyInvocations.append(
            (localHostId: localHostId, revision: blob.revision)
        )
        #endif

        let materialGeneration = await materialStore.currentGeneration(
            for: localHostId
        )
        let result: RemoteCredentialMaterialResult
        do {
            result = try await materialWorker.decrypt(
                serverId: remote.id,
                blob: blob
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordCorruptAttempt(
                localHostId: localHostId,
                revision: blob.revision
            )
            throw error
        }

        switch result {
        case .missingKey(let keyID):
            guard let validation = try await materialStore
                .beginGenerationValidation(
                    for: localHostId,
                    expectedGeneration: materialGeneration
                ) else {
                return
            }
            do {
                try Task.checkCancellation()
                guard remotePullIsAllowed(for: localHostId) else {
                    await materialStore.finishGenerationValidation(validation)
                    return
                }
                preferences.mutate {
                    $0.state = .waitingForKey(observedKeyID: keyID)
                }
            } catch {
                await materialStore.finishGenerationValidation(validation)
                throw error
            }
            await materialStore.finishGenerationValidation(validation)
            throw EnvelopeCrypto.Error.decryptionFailed

        case .material(let material):
            let generationBeforeApply = await materialStore.currentGeneration(
                for: localHostId
            )
            guard generationBeforeApply == materialGeneration,
                  remotePullIsAllowed(for: localHostId) else {
                return
            }

            let commit: RemoteCredentialMaterialCommit
            do {
                guard let pendingCommit = try await materialStore.applyRemote(
                    material,
                    for: localHostId,
                    expectedGeneration: materialGeneration
                ) else {
                    return
                }
                commit = pendingCommit
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                recordCorruptAttempt(
                    localHostId: localHostId,
                    revision: blob.revision
                )
                throw error
            }

            do {
                try Task.checkCancellation()
            } catch {
                try await abortRemoteCommit(commit, localHostId: localHostId)
                throw error
            }

            let generationAfterApply = await materialStore.currentGeneration(
                for: localHostId
            )
            do {
                try Task.checkCancellation()
            } catch {
                try await abortRemoteCommit(commit, localHostId: localHostId)
                throw error
            }
            guard sessionStore.hosts.contains(where: { $0.id == localHostId }) else {
                try await materialStore.resolveRemoteCommit(commit, as: .discard)
                return
            }
            guard generationAfterApply == materialGeneration,
                  remotePullIsAllowed(for: localHostId) else {
                try await materialStore.resolveRemoteCommit(commit, as: .rollback)
                return
            }

            do {
                try sessionStore.applyRemoteCredentialSource(commit)

                let corruptKey = CorruptCredentialKey(
                    hostId: localHostId,
                    revision: blob.revision
                )
                preferences.mutate {
                    $0.decryptAttemptCounts[corruptKey] = nil
                    $0.lastAppliedRevision[localHostId] = blob.revision
                    $0.hostsWithCloudPayload.insert(localHostId)
                }
                try await materialStore.resolveRemoteCommit(commit, as: .commit)
            } catch {
                let originalError = error
                do {
                    try await materialStore.resolveRemoteCommit(commit, as: .rollback)
                } catch {
                    let rollbackDescription = String(describing: error)
                    Self.log.error(
                        "credential rollback failed: \(localHostId, privacy: .public): \(rollbackDescription, privacy: .public)"
                    )
                }
                recordCorruptAttempt(
                    localHostId: localHostId,
                    revision: blob.revision
                )
                throw originalError
            }
        }
    }

    private func abortRemoteCommit(
        _ commit: RemoteCredentialMaterialCommit,
        localHostId: UUID
    ) async throws {
        if sessionStore.hosts.contains(where: { $0.id == localHostId }) {
            try await materialStore.resolveRemoteCommit(commit, as: .rollback)
        } else {
            try await materialStore.resolveRemoteCommit(commit, as: .discard)
        }
    }

    private func remotePullIsAllowed(for localHostId: UUID) -> Bool {
        guard preferences.prefs.deleteCredentialsFromCloudInProgress == nil,
              case .enabled = preferences.prefs.state else {
            return false
        }
        return sessionStore.hosts.contains { $0.id == localHostId }
    }

    private func recordCorruptAttempt(localHostId: UUID, revision: Int64) {
        let key = CorruptCredentialKey(
            hostId: localHostId,
            revision: revision
        )
        let nextCount = (preferences.prefs.decryptAttemptCounts[key] ?? 0) + 1
        preferences.mutate {
            if nextCount >= 3 {
                $0.corruptCredentials.insert(key)
                $0.lastAppliedRevision[localHostId] = revision
                $0.decryptAttemptCounts[key] = nil
            } else {
                $0.decryptAttemptCounts[key] = nextCount
            }
        }
    }
}
