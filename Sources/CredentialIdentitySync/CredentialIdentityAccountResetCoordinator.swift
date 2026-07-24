import CredentialIdentitySecurity
import CredentialIdentityStore
import Foundation

/// Removes all credential identity state bound to the previous iCloud account.
///
/// Material is restored if either deletion or metadata persistence fails, so a
/// transient local error cannot leave an identity partially erased.
@MainActor
public final class CredentialIdentityAccountResetCoordinator {
	private let store: CredentialIdentityStore
	private let materialStore: CredentialIdentityMaterialStore

	public init(
		store: CredentialIdentityStore,
		materialStore: CredentialIdentityMaterialStore
	) {
		self.store = store
		self.materialStore = materialStore
	}

	public func resetForAccountChange() async throws {
		try await store.withTransaction {
			try await self.resetWithinTransaction()
		}
	}

	private func resetWithinTransaction() async throws {
		try await store.load()
		let identities = store.identities
		var snapshots: [
			(
				identity: CredentialIdentity,
				material: CredentialIdentityMaterial
			)
		] = []

		for identity in identities {
			let material = try await materialStore.snapshot(for: identity)
			snapshots.append((identity, material))
		}

		var attempted: [
			(
				identity: CredentialIdentity,
				material: CredentialIdentityMaterial
			)
		] = []
		do {
			for snapshot in snapshots {
				attempted.append(snapshot)
				try await materialStore.delete(identity: snapshot.identity)
			}
			try await store.resetForAccountChange()
		} catch {
			let originalError = error
			var rollbackErrors: [String] = []
			for snapshot in attempted.reversed()
			where snapshot.material.hasAnyMaterial {
				do {
					try await materialStore.replaceMaterial(
						for: snapshot.identity,
						with: snapshot.material
					)
				} catch {
					rollbackErrors.append(String(describing: error))
				}
			}
			if !rollbackErrors.isEmpty {
				throw CredentialIdentityRollbackError(
					operation: originalError,
					rollback: CredentialIdentityAccountResetRollbackError(
						failures: rollbackErrors
					)
				)
			}
			throw originalError
		}
	}
}

private struct CredentialIdentityAccountResetRollbackError: Error {
	let failures: [String]
}
