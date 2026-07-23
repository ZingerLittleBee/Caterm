import CredentialIdentityStore
import Foundation
import ManagedKeyStore

public struct CredentialIdentityMaterial: Equatable, Sendable {
	public var password: Data?
	public var passphrase: Data?
	public var privateKey: Data?
	public var secureEnclaveKeyBlob: Data?

	public init(
		password: Data? = nil,
		passphrase: Data? = nil,
		privateKey: Data? = nil,
		secureEnclaveKeyBlob: Data? = nil
	) {
		self.password = password
		self.passphrase = passphrase
		self.privateKey = privateKey
		self.secureEnclaveKeyBlob = secureEnclaveKeyBlob
	}
}

public enum CredentialIdentityMaterialAvailability: Equatable, Sendable {
	case available
	case unavailableOnThisDevice
	case incomplete
}

public enum CredentialIdentityMaterialStoreError: Error, Equatable {
	case invalidMaterialForSource
	case materialUnavailable
	case secureEnclavePublicKeyMismatch
}

public actor CredentialIdentityMaterialStore {
	private let secrets: any IdentitySecretStoring
	private let managedKeys: ManagedKeyStore
	private let secureEnclave: any SecureEnclaveIdentityKeyProviding

	public init(
		secrets: any IdentitySecretStoring = IdentityKeychainSecretStore(),
		managedKeys: ManagedKeyStore = ManagedKeyStore(),
		secureEnclave: any SecureEnclaveIdentityKeyProviding =
			SystemSecureEnclaveIdentityKeyProvider()
	) {
		self.secrets = secrets
		self.managedKeys = managedKeys
		self.secureEnclave = secureEnclave
	}

	public func replaceMaterial(
		for identity: CredentialIdentity,
		with material: CredentialIdentityMaterial
	) async throws {
		try validate(material, for: identity.source)
		let materialID = identity.source.materialID
		let previous = try snapshot(materialID: materialID)
		do {
			try await write(
				material,
				materialID: materialID
			)
		} catch {
			let originalError = error
			try? await restore(previous, materialID: materialID)
			throw originalError
		}
	}

	public func snapshot(
		for identity: CredentialIdentity
	) throws -> CredentialIdentityMaterial {
		try snapshot(materialID: identity.source.materialID)
	}

	public func availability(
		for identity: CredentialIdentity
	) throws -> CredentialIdentityMaterialAvailability {
		let material = try snapshot(for: identity)
		switch identity.source {
		case .password:
			return material.password == nil ? .incomplete : .available
		case .managedKey(_, let hasPassphrase),
		     .sshCertificate(_, _, let hasPassphrase):
			guard material.privateKey != nil else {
				return .incomplete
			}
			return hasPassphrase && material.passphrase == nil
				? .incomplete
				: .available
		case .secureEnclaveP256:
			return material.secureEnclaveKeyBlob == nil
				? .unavailableOnThisDevice
				: .available
		}
	}

	public func createSecureEnclaveIdentity(
		name: String,
		username: String,
		originDeviceID: UUID,
		localizedReason: String
	) async throws -> CredentialIdentity {
		guard secureEnclave.isAvailable else {
			throw SecureEnclaveIdentityError.unavailable
		}
		let materialID = CredentialMaterialID()
		let key = try secureEnclave.create(localizedReason: localizedReason)
		let identity = CredentialIdentity(
			name: name,
			username: username,
			source: .secureEnclaveP256(
				materialID: materialID,
				publicKey: key.publicKeyDER,
				originDeviceID: originDeviceID
			)
		)
		do {
			try secrets.write(
				key.dataRepresentation,
				account: account(materialID, kind: .secureEnclaveKey)
			)
			return identity
		} catch {
			try? await delete(materialID: materialID)
			throw error
		}
	}

	public func secureEnclaveKey(
		for identity: CredentialIdentity,
		localizedReason: String
	) throws -> SecureEnclaveIdentityKey {
		guard case .secureEnclaveP256(
			let materialID,
			let expectedPublicKey,
			_
		) = identity.source else {
			throw CredentialIdentityMaterialStoreError.invalidMaterialForSource
		}
		guard let blob = try secrets.read(
			account: account(materialID, kind: .secureEnclaveKey)
		) else {
			throw CredentialIdentityMaterialStoreError.materialUnavailable
		}
		let key = try secureEnclave.restore(
			dataRepresentation: blob,
			localizedReason: localizedReason
		)
		guard key.publicKeyDER == expectedPublicKey else {
			throw CredentialIdentityMaterialStoreError
				.secureEnclavePublicKeyMismatch
		}
		return key
	}

	public func delete(identity: CredentialIdentity) async throws {
		try await delete(materialID: identity.source.materialID)
	}

	private func validate(
		_ material: CredentialIdentityMaterial,
		for source: CredentialIdentitySource
	) throws {
		let valid: Bool = switch source {
		case .password:
			material.password != nil
				&& material.passphrase == nil
				&& material.privateKey == nil
				&& material.secureEnclaveKeyBlob == nil
		case .managedKey(_, let hasPassphrase),
		     .sshCertificate(_, _, let hasPassphrase):
			material.password == nil
				&& material.privateKey != nil
				&& (!hasPassphrase || material.passphrase != nil)
				&& material.secureEnclaveKeyBlob == nil
		case .secureEnclaveP256:
			material.password == nil
				&& material.passphrase == nil
				&& material.privateKey == nil
				&& material.secureEnclaveKeyBlob != nil
		}
		guard valid else {
			throw CredentialIdentityMaterialStoreError.invalidMaterialForSource
		}
	}

	private func snapshot(
		materialID: CredentialMaterialID
	) throws -> CredentialIdentityMaterial {
		CredentialIdentityMaterial(
			password: try secrets.read(
				account: account(materialID, kind: .password)
			),
			passphrase: try secrets.read(
				account: account(materialID, kind: .passphrase)
			),
			privateKey: try managedKeys.read(
				materialID: materialID.rawValue
			),
			secureEnclaveKeyBlob: try secrets.read(
				account: account(materialID, kind: .secureEnclaveKey)
			)
		)
	}

	private func write(
		_ material: CredentialIdentityMaterial,
		materialID: CredentialMaterialID
	) async throws {
		try writeSecret(
			material.password,
			materialID: materialID,
			kind: .password
		)
		try writeSecret(
			material.passphrase,
			materialID: materialID,
			kind: .passphrase
		)
		try writeSecret(
			material.secureEnclaveKeyBlob,
			materialID: materialID,
			kind: .secureEnclaveKey
		)
		if let privateKey = material.privateKey {
			_ = try await managedKeys.write(
				materialID: materialID.rawValue,
				bytes: privateKey
			)
		} else {
			try await managedKeys.delete(materialID: materialID.rawValue)
		}
	}

	private func restore(
		_ material: CredentialIdentityMaterial,
		materialID: CredentialMaterialID
	) async throws {
		try await write(material, materialID: materialID)
	}

	private func delete(materialID: CredentialMaterialID) async throws {
		var firstError: (any Error)?
		for kind in [
			CredentialIdentityKeychainContract.SecretKind.password,
			.passphrase,
			.secureEnclaveKey,
		] {
			do {
				try secrets.delete(account: account(materialID, kind: kind))
			} catch {
				if firstError == nil {
					firstError = error
				}
			}
		}
		do {
			try await managedKeys.delete(materialID: materialID.rawValue)
		} catch {
			if firstError == nil {
				firstError = error
			}
		}
		if let firstError {
			throw firstError
		}
	}

	private func writeSecret(
		_ data: Data?,
		materialID: CredentialMaterialID,
		kind: CredentialIdentityKeychainContract.SecretKind
	) throws {
		let account = account(materialID, kind: kind)
		if let data {
			try secrets.write(data, account: account)
		} else {
			try secrets.delete(account: account)
		}
	}

	private func account(
		_ materialID: CredentialMaterialID,
		kind: CredentialIdentityKeychainContract.SecretKind
	) -> String {
		CredentialIdentityKeychainContract.account(
			materialID: materialID,
			kind: kind
		)
	}
}
