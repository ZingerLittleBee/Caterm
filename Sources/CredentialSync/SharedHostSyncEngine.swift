import CredentialSyncStore
import CredentialSyncTypes
import Foundation
import HostRepositoryCore
import ServerSyncClient

public enum SharedHostSyncRequest: Sendable, Equatable {
	case automatic
	case forceFull
	case incremental
}

public enum SharedHostSyncResult: Sendable {
	case synchronized(mode: HostSyncMode, operations: [SyncOperation])
	case handledDestructiveCredentialDeletion
}

/// Platform-neutral Host and credential synchronization behavior.
///
/// Lifecycle adapters decide when to call this module. The module owns mode
/// selection, metadata reconciliation, credential effects, checkpoint
/// ordering, and the stale-remote fallback shared by macOS and iOS.
@MainActor
public final class SharedHostSyncEngine {
	private let client: any IncrementalHostSyncClient
	private let repository: any HostCredentialRepository
	private let credentialEngine: HostCredentialSyncEngine

	public init(
		client: any IncrementalHostSyncClient,
		repository: any HostCredentialRepository,
		credentialSync: CredentialSyncPreferencesStore,
		masterKeyStore: KeychainSyncMasterKeyStore,
		materialStore: any HostCredentialMaterialStoring
	) {
		self.client = client
		self.repository = repository
		self.credentialEngine = HostCredentialSyncEngine(
			client: client,
			repository: repository,
			preferences: credentialSync,
			masterKeyStore: masterKeyStore,
			materialStore: materialStore
		)
	}

	public func synchronize(
		request: SharedHostSyncRequest
	) async throws -> SharedHostSyncResult {
		let cycle = try await credentialEngine.beginCycle()
		guard case let .hostSync(requiresFullSnapshot) = cycle else {
			return .handledDestructiveCredentialDeletion
		}

		let mode: HostSyncMode = switch request {
		case .automatic:
			requiresFullSnapshot
				? .forceFull
				: await client.preferredHostSyncMode()
		case .forceFull:
			.forceFull
		case .incremental:
			.incremental
		}

		do {
			let operations = try await runPass(mode: mode)
			return .synchronized(mode: mode, operations: operations)
		} catch let error as ServerSyncError {
			guard case .remoteHostNotFound = error, mode != .forceFull else {
				throw error
			}
			let operations = try await runPass(mode: .forceFull)
			return .synchronized(mode: .forceFull, operations: operations)
		}
	}

	public func handleLocalCredentialChange(hostID: UUID) -> Bool {
		credentialEngine.handleLocalCredentialChange(hostId: hostID)
	}

	private func runPass(mode: HostSyncMode) async throws -> [SyncOperation] {
		let credentialOperations = credentialEngine.credentialHostIDs().map {
			SyncOperation.updateRemoteCredentials(localHostId: $0)
		}
		return try await HostSynchronization.synchronize(
			repository: repository,
			client: client,
			mode: mode,
			additionalOperations: credentialOperations,
			afterApply: { [weak self] operation, batch in
				guard let self else { return }
				try await self.applyCredentialEffects(
					for: operation,
					credentialBlobs: batch.credentialBlobsByServerId
				)
			},
			didCommitCheckpoint: { [weak self] in
				self?.credentialEngine.didCommitCheckpoint()
			}
		)
	}

	private func applyCredentialEffects(
		for operation: SyncOperation,
		credentialBlobs: [String: CredentialBlob]
	) async throws {
		switch operation {
		case let .createLocal(remote):
			if let blob = credentialBlobs[remote.id],
			   let local = repository.hostSnapshot.last(where: {
				   $0.serverId == remote.id
			   }) {
				try await credentialEngine.applyRemoteBlob(
					localHostId: local.id,
					remote: remote,
					blob: blob
				)
			}
		case let .updateLocal(localHostID, remote):
			if let blob = credentialBlobs[remote.id] {
				try await credentialEngine.applyRemoteBlob(
					localHostId: localHostID,
					remote: remote,
					blob: blob
				)
			}
		case let .updateRemoteCredentials(localHostID):
			try await credentialEngine.pushLocalCredential(hostId: localHostID)
		case .createRemote, .updateRemote, .deleteLocal:
			break
		}
	}
}
