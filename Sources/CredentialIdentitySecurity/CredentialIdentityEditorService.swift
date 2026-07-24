import CredentialIdentityStore
import Foundation
import ManagedKeyStore

public enum CredentialIdentityEditorKind: Sendable {
	case password
	case managedKey
	case sshCertificate
	case secureEnclaveP256
}

public struct CredentialIdentityEditorInput: Sendable {
	public let existingIdentity: CredentialIdentity?
	public let kind: CredentialIdentityEditorKind
	public let name: String
	public let username: String
	public let password: Data?
	public let privateKey: Data?
	public let publicCertificate: Data?
	public let hasPassphrase: Bool
	public let passphrase: Data?
	public let originDeviceID: UUID
	public let localizedReason: String

	public init(
		existingIdentity: CredentialIdentity?,
		kind: CredentialIdentityEditorKind,
		name: String,
		username: String,
		password: Data? = nil,
		privateKey: Data? = nil,
		publicCertificate: Data? = nil,
		hasPassphrase: Bool = false,
		passphrase: Data? = nil,
		originDeviceID: UUID,
		localizedReason: String
	) {
		self.existingIdentity = existingIdentity
		self.kind = kind
		self.name = name
		self.username = username
		self.password = password
		self.privateKey = privateKey
		self.publicCertificate = publicCertificate
		self.hasPassphrase = hasPassphrase
		self.passphrase = passphrase
		self.originDeviceID = originDeviceID
		self.localizedReason = localizedReason
	}
}

public actor CredentialIdentityEditorService {
	private let materialStore: CredentialIdentityMaterialStore

	public init(materialStore: CredentialIdentityMaterialStore) {
		self.materialStore = materialStore
	}

	@discardableResult
	public func save(
		_ input: CredentialIdentityEditorInput,
		to store: CredentialIdentityStore
	) async throws -> CredentialIdentity {
		try await store.withTransaction {
			try await self.saveWithinTransaction(input, to: store)
		}
	}

	private func saveWithinTransaction(
		_ input: CredentialIdentityEditorInput,
		to store: CredentialIdentityStore
	) async throws -> CredentialIdentity {
		try await store.load()
		let existingIdentity: CredentialIdentity?
		if let inputIdentity = input.existingIdentity {
			existingIdentity =
				await store.identity(id: inputIdentity.id) ?? inputIdentity
		} else {
			existingIdentity = nil
		}
		let input = input.replacingExistingIdentity(
			existingIdentity
		)
		if input.kind == .secureEnclaveP256,
		   input.existingIdentity == nil {
			return try await createSecureEnclaveIdentity(input, store: store)
		}

		let previous: CredentialIdentityMaterial?
		if let existingIdentity = input.existingIdentity {
			previous = try await materialStore.snapshot(
				for: existingIdentity
			)
		} else {
			previous = nil
		}
		let materialID = input.existingIdentity?.source.materialID
			?? CredentialMaterialID()
		let source = try makeSource(input, materialID: materialID)
		var identity = input.existingIdentity ?? CredentialIdentity(
			name: input.name,
			username: input.username,
			source: source
		)
		identity.name = input.name
		identity.username = input.username
		identity.source = source

		if input.kind != .secureEnclaveP256 {
			let material = makeMaterial(input, previous: previous)
			try await materialStore.replaceMaterial(
				for: identity,
				with: material
			)
		}
		do {
			try await store.upsert(identity)
			return identity
		} catch {
			throw await rollbackSave(
				operationError: error,
				identity: identity,
				previousIdentity: input.existingIdentity,
				previousMaterial: previous
			)
		}
	}

	public func delete(
		_ identity: CredentialIdentity,
		assignedHostIDs:
			@escaping @MainActor @Sendable () -> Set<UUID>,
		from store: CredentialIdentityStore
	) async throws {
		try await store.withTransaction {
			try await store.withDeletionReservation(id: identity.id) {
				try await self.deleteWithinTransaction(
					identity,
					assignedHostIDs: assignedHostIDs(),
					from: store
				)
			}
		}
	}

	private func deleteWithinTransaction(
		_ identity: CredentialIdentity,
		assignedHostIDs: Set<UUID>,
		from store: CredentialIdentityStore
	) async throws {
		try await store.load()
		let previous = try await materialStore.snapshot(for: identity)
		try await materialStore.delete(identity: identity)
		do {
			try await store.delete(
				id: identity.id,
				assignedHostIDs: assignedHostIDs
			)
		} catch {
			let operationError = error
			guard previous.hasAnyMaterial else {
				throw operationError
			}
			do {
				try await materialStore.replaceMaterial(
					for: identity,
					with: previous
				)
			} catch {
				throw CredentialIdentityRollbackError(
					operation: operationError,
					rollback: error
				)
			}
			throw operationError
		}
	}

	@discardableResult
	public func replaceSecureEnclaveKey(
		for identity: CredentialIdentity,
		originDeviceID: UUID,
		localizedReason: String,
		in store: CredentialIdentityStore
	) async throws -> CredentialIdentity {
		try await store.withTransaction {
			try await self.replaceSecureEnclaveKeyWithinTransaction(
				for: identity,
				originDeviceID: originDeviceID,
				localizedReason: localizedReason,
				in: store
			)
		}
	}

	private func replaceSecureEnclaveKeyWithinTransaction(
		for identity: CredentialIdentity,
		originDeviceID: UUID,
		localizedReason: String,
		in store: CredentialIdentityStore
	) async throws -> CredentialIdentity {
		try await store.load()
		let storeSnapshot = await store.snapshot()
		let previousMaterial = try await materialStore.snapshot(for: identity)
		let generated = try await materialStore.createSecureEnclaveIdentity(
			name: identity.name,
			username: identity.username,
			originDeviceID: originDeviceID,
			localizedReason: localizedReason
		)
		return try await commitSecureEnclaveReplacement(
			for: identity,
			generated: generated,
			in: store,
			storeSnapshot: storeSnapshot,
			previousMaterial: previousMaterial
		)
	}

	func commitSecureEnclaveReplacement(
		for identity: CredentialIdentity,
		generated: CredentialIdentity,
		in store: CredentialIdentityStore,
		storeSnapshot suppliedStoreSnapshot:
			CredentialIdentityStoreSnapshot? = nil,
		previousMaterial suppliedPreviousMaterial:
			CredentialIdentityMaterial? = nil
	) async throws -> CredentialIdentity {
		let storeSnapshot: CredentialIdentityStoreSnapshot
		if let suppliedStoreSnapshot {
			storeSnapshot = suppliedStoreSnapshot
		} else {
			storeSnapshot = await store.snapshot()
		}
		let previousMaterial: CredentialIdentityMaterial
		if let suppliedPreviousMaterial {
			previousMaterial = suppliedPreviousMaterial
		} else {
			previousMaterial = try await materialStore.snapshot(for: identity)
		}
		var replacement = identity
		replacement.source = generated.source
		var replacementStoreSnapshot: CredentialIdentityStoreSnapshot?
		do {
			try await store.upsert(replacement)
			replacementStoreSnapshot = await store.snapshot()
			try await materialStore.delete(identity: identity)
			return replacement
		} catch {
			let operationError = error
			var rollbackErrors: [String] = []
			var restoredPreviousMetadata = false
			do {
				try await store.restore(storeSnapshot)
				restoredPreviousMetadata = true
			} catch {
				rollbackErrors.append(String(describing: error))
			}
			var restoredPreviousMaterial = !previousMaterial.hasAnyMaterial
			if previousMaterial.hasAnyMaterial {
				do {
					try await materialStore.replaceMaterial(
						for: identity,
						with: previousMaterial
					)
					restoredPreviousMaterial = true
				} catch {
					rollbackErrors.append(String(describing: error))
				}
			}
			if restoredPreviousMetadata && restoredPreviousMaterial {
				do {
					try await materialStore.delete(identity: generated)
				} catch {
					rollbackErrors.append(String(describing: error))
				}
			} else if restoredPreviousMetadata,
			          let replacementStoreSnapshot {
				do {
					try await store.restore(replacementStoreSnapshot)
				} catch {
					rollbackErrors.append(String(describing: error))
				}
			}
			guard !rollbackErrors.isEmpty else {
				throw operationError
			}
			throw CredentialIdentityRollbackError(
				operation: operationError,
				rollback: CredentialIdentityEditorRollbackFailures(
					failures: rollbackErrors
				)
			)
		}
	}

	private func createSecureEnclaveIdentity(
		_ input: CredentialIdentityEditorInput,
		store: CredentialIdentityStore
	) async throws -> CredentialIdentity {
		let identity = try await materialStore.createSecureEnclaveIdentity(
			name: input.name,
			username: input.username,
			originDeviceID: input.originDeviceID,
			localizedReason: input.localizedReason
		)
		do {
			try await store.upsert(identity)
			return identity
		} catch {
			let operationError = error
			do {
				try await materialStore.delete(identity: identity)
			} catch {
				throw CredentialIdentityRollbackError(
					operation: operationError,
					rollback: error
				)
			}
			throw operationError
		}
	}

	private func makeSource(
		_ input: CredentialIdentityEditorInput,
		materialID: CredentialMaterialID
	) throws -> CredentialIdentitySource {
		switch input.kind {
		case .password:
			return .password(materialID: materialID)
		case .managedKey:
			return .managedKey(
				materialID: materialID,
				hasPassphrase: input.hasPassphrase
			)
		case .sshCertificate:
			let existingCertificate: Data? = if case .sshCertificate(
				_,
				let certificate,
				_
			) = input.existingIdentity?.source {
				certificate
			} else {
				nil
			}
			guard let certificate =
				input.publicCertificate ?? existingCertificate else {
				throw CredentialIdentityValidationError
					.emptyPublicCertificate
			}
			return .sshCertificate(
				materialID: materialID,
				publicCertificate: certificate,
				hasPassphrase: input.hasPassphrase
			)
		case .secureEnclaveP256:
			guard let existingIdentity = input.existingIdentity else {
				throw SecureEnclaveIdentityError.unavailable
			}
			return existingIdentity.source
		}
	}

	private func makeMaterial(
		_ input: CredentialIdentityEditorInput,
		previous: CredentialIdentityMaterial?
	) -> CredentialIdentityMaterial {
		switch input.kind {
		case .password:
			return CredentialIdentityMaterial(
				password: input.password ?? previous?.password
			)
		case .managedKey, .sshCertificate:
			return CredentialIdentityMaterial(
				passphrase: input.hasPassphrase
					? input.passphrase ?? previous?.passphrase
					: nil,
				privateKey: input.privateKey ?? previous?.privateKey
			)
		case .secureEnclaveP256:
			return previous ?? CredentialIdentityMaterial()
		}
	}

	private func rollbackSave(
		operationError: any Error,
		identity: CredentialIdentity,
		previousIdentity: CredentialIdentity?,
		previousMaterial: CredentialIdentityMaterial?
	) async -> any Error {
		do {
			if let previousIdentity, let previousMaterial {
				try await materialStore.replaceMaterial(
					for: previousIdentity,
					with: previousMaterial
				)
			} else {
				try await materialStore.delete(identity: identity)
			}
			return operationError
		} catch {
			return CredentialIdentityRollbackError(
				operation: operationError,
				rollback: error
			)
		}
	}
}

public enum CredentialIdentityFileImporter {
	public static func read(_ url: URL) async throws -> Data {
		try await Task.detached(priority: .userInitiated) {
			let accessed = url.startAccessingSecurityScopedResource()
			defer {
				if accessed {
					url.stopAccessingSecurityScopedResource()
				}
			}
			let data = try Data(contentsOf: url)
			guard data.count <= ManagedKeyStore.maxBytes else {
				throw ManagedKeyStore.Error.tooLarge
			}
			return data
		}.value
	}
}

private struct CredentialIdentityEditorRollbackFailures: Error {
	let failures: [String]
}

private extension CredentialIdentityEditorInput {
	func replacingExistingIdentity(
		_ identity: CredentialIdentity?
	) -> CredentialIdentityEditorInput {
		CredentialIdentityEditorInput(
			existingIdentity: identity,
			kind: kind,
			name: name,
			username: username,
			password: password,
			privateKey: privateKey,
			publicCertificate: publicCertificate,
			hasPassphrase: hasPassphrase,
			passphrase: passphrase,
			originDeviceID: originDeviceID,
			localizedReason: localizedReason
		)
	}
}
