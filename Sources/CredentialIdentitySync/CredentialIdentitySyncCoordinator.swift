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
}

@MainActor
public final class CredentialIdentitySyncCoordinator {
	private let store: CredentialIdentityStore
	private let materialStore: CredentialIdentityMaterialStore
	private let client: any CredentialIdentitySyncClient
	private let masterKeys: any IdentitySyncMasterKeyProviding

	public init(
		store: CredentialIdentityStore,
		materialStore: CredentialIdentityMaterialStore,
		client: any CredentialIdentitySyncClient,
		masterKeys: any IdentitySyncMasterKeyProviding
	) {
		self.store = store
		self.materialStore = materialStore
		self.client = client
		self.masterKeys = masterKeys
	}

	public func sync() async throws {
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
			guard shouldApplyRemote(record.identity) else {
				continue
			}
			let previousIdentity = store.identity(id: record.identity.id)
			let previousMaterial: CredentialIdentityMaterial?
			if let previousIdentity {
				previousMaterial = try await materialStore.snapshot(
					for: previousIdentity
				)
			} else {
				previousMaterial = nil
			}
			let incomingMaterial = try await openMaterial(record)
			do {
				if let incomingMaterial {
					try await materialStore.replaceMaterial(
						for: record.identity,
						with: incomingMaterial
					)
				}
				_ = try store.applyRemote(record.identity)
			} catch {
				if let previousIdentity, let previousMaterial {
					try? await materialStore.replaceMaterial(
						for: previousIdentity,
						with: previousMaterial
					)
				} else if previousIdentity == nil {
					try? await materialStore.delete(
						identity: record.identity
					)
				}
				throw error
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
			try store.acknowledgePush(id: id, serverID: serverID)
		}
	}

	private func pushDeletions() async throws {
		for id in store.pendingDeletedIdentityIDs.sorted(by: {
			$0.uuidString < $1.uuidString
		}) {
			try await client.deleteCredentialIdentity(id: id.uuidString)
			try store.acknowledgeDeletion(id: id)
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
			let previousMaterial = try await materialStore.snapshot(
				for: identity
			)
			do {
				try await materialStore.delete(identity: identity)
				try store.applyRemoteTombstone(id: identity.id)
			} catch {
				try? await materialStore.replaceMaterial(
					for: identity,
					with: previousMaterial
				)
				throw error
			}
		}
	}

	private func shouldApplyRemote(_ remote: CredentialIdentity) -> Bool {
		guard let local = store.identity(id: remote.id) else {
			return true
		}
		if store.locallyDirtyIdentityIDs.contains(local.id) {
			if local.revision != remote.revision {
				return remote.revision > local.revision
			}
			return remote.updatedAt >= local.updatedAt
		}
		return true
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
