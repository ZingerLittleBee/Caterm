import Foundation
import HostRepositoryCore
import KeychainStore
import SessionStore

/// Repository capabilities required by the shared credential-sync behavior.
/// Platform adapters keep UI and lifecycle concerns outside this seam.
@MainActor
public protocol HostCredentialRepository: HostRepository {
	func managedKeyPath(for hostID: UUID) -> String
	func applyRemoteCredentialSource(
		_ commit: RemoteCredentialMaterialCommit
	) throws
	func resetCredentialMaterialForAccountChange() async throws
}

/// Transactional credential-material seam shared by macOS and iOS.
public protocol HostCredentialMaterialStoring: Sendable {
	func snapshot(
		for hostID: UUID,
		selecting selection: CredentialMaterialSelection,
		interaction: KeychainReadInteraction
	) async throws -> StoredCredentialMaterialSnapshot
	func currentGeneration(for hostID: UUID) async -> UInt64
	func beginGenerationValidation(
		for hostID: UUID,
		expectedGeneration: UInt64
	) async throws -> CredentialGenerationValidation?
	func finishGenerationValidation(
		_ validation: CredentialGenerationValidation
	) async
	func applyRemote(
		_ secrets: HostSecrets,
		for hostID: UUID,
		expectedGeneration: UInt64
	) async throws -> RemoteCredentialMaterialCommit?
	func resolveRemoteCommit(
		_ commit: RemoteCredentialMaterialCommit,
		as disposition: RemoteCredentialCommitDisposition
	) async throws
}

extension SessionCredentialMaterialStore: HostCredentialMaterialStoring {}

extension SessionStore: HostCredentialRepository {}
