import CredentialIdentitySecurity
import CredentialIdentityStore
import CredentialSyncStore
import CredentialSyncTypes
import CryptoKit
import Foundation

public protocol IdentitySyncMasterKeyProviding: Sendable {
	func identitySyncKey() async throws -> (
		keyID: String,
		key: SymmetricKey
	)?
	func identitySyncKey(keyID: String) async throws -> SymmetricKey?
}

extension KeychainSyncMasterKeyStore: IdentitySyncMasterKeyProviding {
	public func identitySyncKey() throws -> (
		keyID: String,
		key: SymmetricKey
	)? {
		try lookupAny()
	}

	public func identitySyncKey(
		keyID: String
	) throws -> SymmetricKey? {
		try lookup(keyID: keyID)
	}
}

public enum CredentialIdentitySyncError: Error, Equatable {
	case masterKeyUnavailable
	case unsupportedCryptoVersion(Int64)
	case encryptedMaterialMissing(UUID)
	case remoteSuperseded(UUID)
	case transactionRollbackFailed(operation: String, rollback: [String])
}

@MainActor
public final class CredentialIdentitySyncCoordinator {
	private let store: CredentialIdentityStore
	private let materialStore: CredentialIdentityMaterialStore
	private let client: any CredentialIdentitySyncClient
	private let masterKeys: any IdentitySyncMasterKeyProviding
	private let assignedHostIDs: @MainActor (UUID) -> Set<UUID>

	public init(
		store: CredentialIdentityStore,
		materialStore: CredentialIdentityMaterialStore,
		client: any CredentialIdentitySyncClient,
		masterKeys: any IdentitySyncMasterKeyProviding,
		assignedHostIDs:
			@escaping @MainActor (UUID) -> Set<UUID> = { _ in [] }
	) {
		self.store = store
		self.materialStore = materialStore
		self.client = client
		self.masterKeys = masterKeys
		self.assignedHostIDs = assignedHostIDs
	}

	public func sync() async throws {
		try await store.withTransaction {
			try await self.syncWithinTransaction()
		}
	}

	private func syncWithinTransaction() async throws {
		try await store.load()
		let remote = try await client.listCredentialIdentities()
		try await applyRemote(remote)
		try await removeCleanRemoteTombstones(remote: remote)
		try await pushDirty()
		try await pushDeletions()
	}

	private func applyRemote(
		_ records: [CredentialIdentitySyncRecord]
	) async throws {
		for record in records {
			guard store.wouldApplyRemote(record.identity) else {
				continue
			}
			let storeSnapshot = store.snapshot()
			let previousIdentity = store.identity(id: record.identity.id)
			let previousMaterial: CredentialIdentityMaterial?
			if let previousIdentity {
				previousMaterial = try await materialStore.snapshot(
					for: previousIdentity
				)
			} else {
				previousMaterial = nil
			}
			let destinationMaterial =
				try await materialStore.snapshot(for: record.identity)
			let incomingMaterial = try await openMaterial(record)
			do {
				if let incomingMaterial {
					try await materialStore.replaceMaterial(
						for: record.identity,
						with: incomingMaterial
					)
				}
				let applied = try await store.applyRemote(record.identity)
				guard applied else {
					throw CredentialIdentitySyncError.remoteSuperseded(
						record.identity.id
					)
				}
				if let previousIdentity,
				   previousIdentity.source.materialID
					!= record.identity.source.materialID {
					try await materialStore.delete(identity: previousIdentity)
				}
			} catch {
				throw await rollbackRemoteMutation(
					operationError: error,
					storeSnapshot: storeSnapshot,
					previousIdentity: previousIdentity,
					previousMaterial: previousMaterial,
					incomingIdentity: record.identity,
					destinationMaterial: destinationMaterial
				)
			}
		}
	}

	private func pushDirty() async throws {
		for id in store.locallyDirtyIdentityIDs.sorted(by: {
			$0.uuidString < $1.uuidString
		}) {
			guard let identity = store.identity(id: id) else {
				continue
			}
			let record = try await sealedRecord(identity)
			let serverID = try await client.upsertCredentialIdentity(record)
			try await store.acknowledgePush(id: id, serverID: serverID)
		}
	}

	private func pushDeletions() async throws {
		for id in store.pendingDeletedIdentityIDs.sorted(by: {
			$0.uuidString < $1.uuidString
		}) {
			try await client.deleteCredentialIdentity(id: id.uuidString)
			try await store.acknowledgeDeletion(id: id)
		}
	}

	private func removeCleanRemoteTombstones(
		remote: [CredentialIdentitySyncRecord]
	) async throws {
		let remoteIDs = Set(remote.map(\.identity.id))
		let localSnapshot = store.identities
		for identity in localSnapshot
		where identity.serverID != nil
			&& !store.locallyDirtyIdentityIDs.contains(identity.id)
			&& !remoteIDs.contains(identity.id) {
			try await store.withDeletionReservation(id: identity.id) {
				guard self.assignedHostIDs(identity.id).isEmpty else {
					return
				}
				let previousMaterial = try await self.materialStore.snapshot(
					for: identity
				)
				let storeSnapshot = self.store.snapshot()
				do {
					try await self.materialStore.delete(identity: identity)
					try await self.store.applyRemoteTombstone(id: identity.id)
				} catch {
					throw await self.rollbackRemoteMutation(
						operationError: error,
						storeSnapshot: storeSnapshot,
						previousIdentity: identity,
						previousMaterial: previousMaterial,
						incomingIdentity: identity,
						destinationMaterial: previousMaterial
					)
				}
			}
		}
	}

	private func rollbackRemoteMutation(
		operationError: any Error,
		storeSnapshot: CredentialIdentityStoreSnapshot,
		previousIdentity: CredentialIdentity?,
		previousMaterial: CredentialIdentityMaterial?,
		incomingIdentity: CredentialIdentity,
		destinationMaterial: CredentialIdentityMaterial
	) async -> any Error {
		var rollbackErrors: [String] = []
		do {
			try await store.restore(storeSnapshot)
		} catch {
			rollbackErrors.append(String(describing: error))
		}
		if let previousIdentity, let previousMaterial {
			do {
				try await restoreMaterial(
					previousMaterial,
					for: previousIdentity
				)
			} catch {
				rollbackErrors.append(String(describing: error))
			}
		}
		if previousIdentity?.source.materialID
			!= incomingIdentity.source.materialID {
			do {
				try await restoreMaterial(
					destinationMaterial,
					for: incomingIdentity
				)
			} catch {
				rollbackErrors.append(String(describing: error))
			}
		}
		guard !rollbackErrors.isEmpty else {
			return operationError
		}
		return CredentialIdentitySyncError.transactionRollbackFailed(
			operation: String(describing: operationError),
			rollback: rollbackErrors
		)
	}

	private func restoreMaterial(
		_ material: CredentialIdentityMaterial,
		for identity: CredentialIdentity
	) async throws {
		if material.hasAnyMaterial {
			try await materialStore.replaceMaterial(
				for: identity,
				with: material
			)
		} else {
			try await materialStore.delete(identity: identity)
		}
	}

	private func sealedRecord(
		_ identity: CredentialIdentity
	) async throws -> CredentialIdentitySyncRecord {
		if identity.source.isDeviceBound {
			return CredentialIdentitySyncRecord(identity: identity)
		}
		guard let master = try await masterKeys.identitySyncKey() else {
			throw CredentialIdentitySyncError.masterKeyUnavailable
		}
		let material = try await materialStore.snapshot(for: identity)
		let serverID = identity.id.uuidString
		return CredentialIdentitySyncRecord(
			identity: identity,
			keyID: master.keyID,
			passwordCiphertext: try seal(
				material.password,
				kind: .password,
				identity: identity,
				serverID: serverID,
				key: master.key
			),
			passphraseCiphertext: try seal(
				material.passphrase,
				kind: .passphrase,
				identity: identity,
				serverID: serverID,
				key: master.key
			),
			privateKeyCiphertext: try seal(
				material.privateKey,
				kind: .privateKey,
				identity: identity,
				serverID: serverID,
				key: master.key
			)
		)
	}

	private func openMaterial(
		_ record: CredentialIdentitySyncRecord
	) async throws -> CredentialIdentityMaterial? {
		if record.identity.source.isDeviceBound {
			return nil
		}
		guard record.cryptoVersion == 1 else {
			throw CredentialIdentitySyncError.unsupportedCryptoVersion(
				record.cryptoVersion
			)
		}
		guard let keyID = record.keyID,
		      let key = try await masterKeys.identitySyncKey(keyID: keyID)
		else {
			throw CredentialIdentitySyncError.masterKeyUnavailable
		}
		let serverID = record.identity.id.uuidString
		let material = CredentialIdentityMaterial(
			password: try open(
				record.passwordCiphertext,
				kind: .password,
				identity: record.identity,
				serverID: serverID,
				key: key
			),
			passphrase: try open(
				record.passphraseCiphertext,
				kind: .passphrase,
				identity: record.identity,
				serverID: serverID,
				key: key
			),
			privateKey: try open(
				record.privateKeyCiphertext,
				kind: .privateKey,
				identity: record.identity,
				serverID: serverID,
				key: key
			)
		)
		switch record.identity.source {
		case .password where material.password == nil,
		     .managedKey where material.privateKey == nil,
		     .sshCertificate where material.privateKey == nil:
			throw CredentialIdentitySyncError.encryptedMaterialMissing(
				record.identity.id
			)
		default:
			return material
		}
	}

	private func seal(
		_ data: Data?,
		kind: FieldKind,
		identity: CredentialIdentity,
		serverID: String,
		key: SymmetricKey
	) throws -> Data? {
		guard let data else { return nil }
		return try EnvelopeCrypto.seal(
			data,
			key: key,
			aad: EnvelopeCrypto.aad(
				serverId: serverID,
				fieldKind: kind,
				revision: identity.revision
			)
		)
	}

	private func open(
		_ data: Data?,
		kind: FieldKind,
		identity: CredentialIdentity,
		serverID: String,
		key: SymmetricKey
	) throws -> Data? {
		guard let data else { return nil }
		return try EnvelopeCrypto.open(
			data,
			key: key,
			aad: EnvelopeCrypto.aad(
				serverId: serverID,
				fieldKind: kind,
				revision: identity.revision
			)
		)
	}
}
