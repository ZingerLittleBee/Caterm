import Foundation
import ServerSyncClient

public enum HostSynchronizationError: Error, Equatable {
	case localHostMissing(UUID)
	case remoteCreationCompensationFailed(
		localHostID: UUID,
		serverID: String,
		detail: String
	)
}

@MainActor
public enum HostSynchronization {
	public typealias OperationHook = @MainActor (
		SyncOperation,
		HostChangeBatch
	) async throws -> Void
	public typealias CheckpointObserver = @MainActor () -> Void

	@discardableResult
	public static func synchronize(
		repository: any HostRepository,
		client: any IncrementalHostSyncClient,
		mode: HostSyncMode,
		additionalOperations: [SyncOperation] = [],
		afterApply: OperationHook? = nil,
		didCommitCheckpoint: CheckpointObserver? = nil
	) async throws -> [SyncOperation] {
		try await repository.prepare()
		try await drainPendingRemoteDeletions(
			repository: repository,
			client: client
		)
		var batch = try await fetch(client: client, mode: mode)
		if batch.tokenExpired {
			batch = try await fetch(client: client, mode: .forceFull)
		}
		try Task.checkCancellation()

		let reconciled: [SyncOperation]
		switch batch.mode {
		case .forceFull:
			reconciled = HostSyncReconciler.reconcileFullSnapshot(
				local: repository.hostSnapshot,
				remote: batch.changedHosts
			)
		case .incremental:
			reconciled = HostSyncReconciler.reconcileDelta(
				local: repository.hostSnapshot,
				changedHosts: batch.changedHosts,
				deletedHostIDs: batch.deletedHostIDs
			)
		}
		let operations = reconciled + additionalOperations
		for operation in operations {
			try Task.checkCancellation()
			try await apply(
				operation,
				repository: repository,
				client: client
			)
			try await afterApply?(operation, batch)
		}

		if let checkpoint = batch.checkpoint {
			try await client.commitHostCheckpoint(checkpoint)
			didCommitCheckpoint?()
		}
		return operations
	}

	private static func fetch(
		client: any IncrementalHostSyncClient,
		mode: HostSyncMode
	) async throws -> HostChangeBatch {
		switch mode {
		case .incremental:
			try await client.fetchHostChanges()
		case .forceFull:
			try await client.fetchHostSnapshotAndCheckpoint()
		}
	}

	private static func drainPendingRemoteDeletions(
		repository: any HostRepository,
		client: any IncrementalHostSyncClient
	) async throws {
		for serverID in try await repository.pendingRemoteDeletionIDs() {
			try Task.checkCancellation()
			try await client.deleteHost(id: serverID)
			try Task.checkCancellation()
			try await repository.clearPendingRemoteDeletion(serverID: serverID)
		}
	}

	private static func apply(
		_ operation: SyncOperation,
		repository: any HostRepository,
		client: any IncrementalHostSyncClient
	) async throws {
		switch operation {
		case .createRemote(let localHostID):
			guard let host = repository.hostSnapshot.first(where: {
				$0.id == localHostID
			}) else {
				throw HostSynchronizationError.localHostMissing(localHostID)
			}
			let output = try await client.createHost(RemoteHostCreateInput(
				name: host.name,
				hostname: host.hostname,
				port: host.port,
				username: host.username,
				jumpHostServerId: host.jumpHostServerId,
				forwards: host.forwards,
				icon: host.icon,
				organization: host.organization,
				automation: host.automation,
				credentialIdentity: host.credentialIdentity,
				metadataUpdatedAt: host.updatedAt
			))
			// Do not insert a cancellation point between remote creation and
			// persisting its identity. Otherwise a retry duplicates the Host.
			do {
				try await repository.assignServerID(output.id, to: localHostID)
			} catch {
				let assignmentError = error
				do {
					try await client.deleteHost(id: output.id)
				} catch {
					do {
						try await repository.recordPendingRemoteDeletion(
							serverID: output.id
						)
					} catch {
						throw HostSynchronizationError
							.remoteCreationCompensationFailed(
								localHostID: localHostID,
								serverID: output.id,
								detail: error.localizedDescription
							)
					}
				}
				throw assignmentError
			}

		case .createLocal(let remote):
			_ = try await repository.createHostFromRemote(remote)

		case .updateRemote(let localHostID, let serverID):
			guard let host = repository.hostSnapshot.first(where: {
				$0.id == localHostID
			}) else {
				throw HostSynchronizationError.localHostMissing(localHostID)
			}
			try await client.updateHost(RemoteHostUpdateInput(
				id: serverID,
				name: host.name,
				hostname: host.hostname,
				port: host.port,
				username: host.username,
				jumpHostServerId: host.jumpHostServerId,
				forwards: host.forwards,
				icon: host.icon,
				organization: host.organization,
				automation: host.automation,
				credentialIdentity: host.credentialIdentity,
				metadataUpdatedAt: host.updatedAt
			))

		case .updateLocal(let localHostID, let remote):
			try await repository.updateHostFromRemote(localID: localHostID, remote: remote)

		case .deleteLocal(let localHostID):
			try await repository.deleteHostFromRemote(localID: localHostID)

		case .updateRemoteCredentials:
			break
		}
	}
}
