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
			try store.resetForAccountChange()
		} catch {
			for snapshot in attempted.reversed()
			where snapshot.material.hasAnyMaterial {
				try? await materialStore.replaceMaterial(
					for: snapshot.identity,
					with: snapshot.material
				)
			}
			throw error
		}
	}
}

private extension CredentialIdentityMaterial {
	var hasAnyMaterial: Bool {
		password != nil
			|| passphrase != nil
			|| privateKey != nil
			|| secureEnclaveKeyBlob != nil
	}
}
