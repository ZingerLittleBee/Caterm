import Foundation
import HostKeyProvisioning
import SSHCommandBuilder
import WorkspaceCore

@MainActor
struct WorkspaceMissingHostRecoveryTransaction {
	struct Dependencies {
		let addHost: (SSHHost) async throws -> Void
		let commitCredential: (SSHHost, String?, PendingKeyMaterial?) async throws -> Void
		let replacePane: (SSHHost, PaneID, Workspace) throws -> Workspace
		let rollbackHost: (UUID) async throws -> Void
	}

	enum RecoveryError: Error, Equatable, LocalizedError {
		case rollbackFailed(operation: String, rollback: String)

		var errorDescription: String? {
			switch self {
			case .rollbackFailed(let operation, let rollback):
				"Host recovery failed (\(operation)), and cleanup also failed (\(rollback))."
			}
		}
	}

	let dependencies: Dependencies

	func run(
		host: SSHHost,
		secret: String?,
		keyMaterial: PendingKeyMaterial?,
		paneID: PaneID,
		workspace: Workspace
	) async throws -> Workspace {
		try await dependencies.addHost(host)
		do {
			try Task.checkCancellation()
			try await dependencies.commitCredential(host, secret, keyMaterial)
			try Task.checkCancellation()
			return try dependencies.replacePane(host, paneID, workspace)
		} catch {
			let operationError = error
			do {
				try await dependencies.rollbackHost(host.id)
			} catch {
				throw RecoveryError.rollbackFailed(
					operation: operationError.localizedDescription,
					rollback: error.localizedDescription
				)
			}
			throw operationError
		}
	}
}
