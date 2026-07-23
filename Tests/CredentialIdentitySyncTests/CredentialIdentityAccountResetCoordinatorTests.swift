import CredentialIdentitySecurity
import CredentialIdentityStore
import CredentialIdentitySync
import Foundation
import ManagedKeyStore
import Testing

@Suite(.serialized)
@MainActor
struct CredentialIdentityAccountResetCoordinatorTests {
	@Test
	func resetRemovesMetadataAndEveryLocalMaterial() async throws {
		let fixture = try AccountResetFixture()
		defer { fixture.cleanup() }
		let identity = fixture.makePasswordIdentity()
		try await fixture.store.upsert(identity)
		try await fixture.materials.replaceMaterial(
			for: identity,
			with: .init(password: Data("old-account".utf8))
		)

		try await fixture.coordinator.resetForAccountChange()

		#expect(fixture.store.identities.isEmpty)
		#expect(fixture.store.locallyDirtyIdentityIDs.isEmpty)
		#expect(fixture.store.pendingDeletedIdentityIDs.isEmpty)
		#expect(
			try await fixture.materials.availability(for: identity)
				== .incomplete
		)
	}

	@Test
	func materialDeletionFailureRestoresSecretAndMetadata() async throws {
		let secrets = FailingAccountResetSecretStore()
		let fixture = try AccountResetFixture(secrets: secrets)
		defer { fixture.cleanup() }
		let identity = fixture.makePasswordIdentity()
		try await fixture.store.upsert(identity)
		try await fixture.materials.replaceMaterial(
			for: identity,
			with: .init(password: Data("keep-me".utf8))
		)
		secrets.failNextDelete()

		await #expect(throws: AccountResetTestError.deleteFailed) {
			try await fixture.coordinator.resetForAccountChange()
		}

		#expect(fixture.store.identity(id: identity.id) != nil)
		#expect(
			try await fixture.materials.snapshot(for: identity).password
				== Data("keep-me".utf8)
		)
	}
}

@MainActor
private struct AccountResetFixture {
	let rootURL: URL
	let store: CredentialIdentityStore
	let materials: CredentialIdentityMaterialStore
	let coordinator: CredentialIdentityAccountResetCoordinator

	init(
		secrets: any IdentitySecretStoring =
			FailingAccountResetSecretStore()
	) throws {
		rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
			"identity-account-reset-\(UUID().uuidString)",
			isDirectory: true
		)
		store = CredentialIdentityStore(
			fileURL: rootURL.appendingPathComponent("identities.json")
		)
		materials = CredentialIdentityMaterialStore(
			secrets: secrets,
			managedKeys: ManagedKeyStore(
				rootURL: rootURL.appendingPathComponent(
					"keys",
					isDirectory: true
				)
			),
			secureEnclave: AccountResetUnavailableSecureEnclave()
		)
		coordinator = CredentialIdentityAccountResetCoordinator(
			store: store,
			materialStore: materials
		)
	}

	func makePasswordIdentity() -> CredentialIdentity {
		CredentialIdentity(
			name: "Previous Account",
			username: "ops",
			source: .password(materialID: CredentialMaterialID())
		)
	}

	func cleanup() {
		try? FileManager.default.removeItem(at: rootURL)
	}
}

private enum AccountResetTestError: Error {
	case deleteFailed
}

private final class FailingAccountResetSecretStore:
	IdentitySecretStoring,
	@unchecked Sendable {
	private let lock = NSLock()
	private var values: [String: Data] = [:]
	private var failDelete = false

	func failNextDelete() {
		lock.withLock { failDelete = true }
	}

	func read(account: String) throws -> Data? {
		lock.withLock { values[account] }
	}

	func write(_ data: Data, account: String) throws {
		lock.withLock { values[account] = data }
	}

	func delete(account: String) throws {
		try lock.withLock {
			if failDelete {
				failDelete = false
				throw AccountResetTestError.deleteFailed
			}
			values[account] = nil
		}
	}
}

private struct AccountResetUnavailableSecureEnclave:
	SecureEnclaveIdentityKeyProviding {
	let isAvailable = false

	func create(localizedReason: String) throws -> SecureEnclaveIdentityKey {
		throw SecureEnclaveIdentityError.unavailable
	}

	func restore(
		dataRepresentation: Data,
		localizedReason: String
	) throws -> SecureEnclaveIdentityKey {
		throw SecureEnclaveIdentityError.unavailable
	}
}
