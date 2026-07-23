import CredentialIdentitySecurity
import CredentialIdentityStore
import Foundation
import SSHCommandBuilder

public enum ResolvedCredentialPayload: Equatable, Sendable {
	case legacyHostOwned
	case password(Data)
	case managedKey(
		privateKey: Data,
		passphrase: Data?,
		publicCertificate: Data?
	)
	case secureEnclaveP256
}

public struct ResolvedIdentityConnection: Equatable, Sendable {
	public let host: SSHHost
	public let identity: CredentialIdentity?
	public let payload: ResolvedCredentialPayload

	public init(
		host: SSHHost,
		identity: CredentialIdentity?,
		payload: ResolvedCredentialPayload
	) {
		self.host = host
		self.identity = identity
		self.payload = payload
	}
}

public enum CredentialIdentityResolutionError: Error, Equatable {
	case missingIdentity(UUID)
	case missingPassword(UUID)
	case missingPrivateKey(UUID)
	case missingPassphrase(UUID)
	case secureEnclaveUnavailable(UUID)
}

public enum CredentialIdentityConnectionResolver {
	public static func resolve(
		host: SSHHost,
		identities: [CredentialIdentity],
		material: CredentialIdentityMaterial?
	) throws -> ResolvedIdentityConnection {
		guard let reference = host.credentialIdentity else {
			return ResolvedIdentityConnection(
				host: host,
				identity: nil,
				payload: .legacyHostOwned
			)
		}
		guard let identity = identities.first(where: {
			$0.id == reference.identityID
		}) else {
			return try legacyFallback(
				host: host,
				reference: reference,
				error: .missingIdentity(reference.identityID)
			)
		}
		let material = material ?? CredentialIdentityMaterial()
		var resolvedHost = host
		resolvedHost.username = identity.username

		let payload: ResolvedCredentialPayload
		switch identity.source {
		case .password:
			guard let password = material.password else {
				return try legacyFallback(
					host: host,
					reference: reference,
					error: .missingPassword(identity.id)
				)
			}
			resolvedHost.credential = .password
			payload = .password(password)
		case .managedKey(_, let hasPassphrase):
			guard let privateKey = material.privateKey else {
				return try legacyFallback(
					host: host,
					reference: reference,
					error: .missingPrivateKey(identity.id)
				)
			}
			if hasPassphrase && material.passphrase == nil {
				return try legacyFallback(
					host: host,
					reference: reference,
					error: .missingPassphrase(identity.id)
				)
			}
			resolvedHost.credential = .keyFile(
				keyPath: "",
				hasPassphrase: hasPassphrase
			)
			payload = .managedKey(
				privateKey: privateKey,
				passphrase: material.passphrase,
				publicCertificate: nil
			)
		case .sshCertificate(
			_,
			let publicCertificate,
			let hasPassphrase
		):
			guard let privateKey = material.privateKey else {
				return try legacyFallback(
					host: host,
					reference: reference,
					error: .missingPrivateKey(identity.id)
				)
			}
			if hasPassphrase && material.passphrase == nil {
				return try legacyFallback(
					host: host,
					reference: reference,
					error: .missingPassphrase(identity.id)
				)
			}
			resolvedHost.credential = .keyFile(
				keyPath: "",
				hasPassphrase: hasPassphrase
			)
			payload = .managedKey(
				privateKey: privateKey,
				passphrase: material.passphrase,
				publicCertificate: publicCertificate
			)
		case .secureEnclaveP256:
			guard material.secureEnclaveKeyBlob != nil else {
				return try legacyFallback(
					host: host,
					reference: reference,
					error: .secureEnclaveUnavailable(identity.id)
				)
			}
			resolvedHost.credential = .agent
			payload = .secureEnclaveP256
		}

		return ResolvedIdentityConnection(
			host: resolvedHost,
			identity: identity,
			payload: payload
		)
	}

	private static func legacyFallback(
		host: SSHHost,
		reference: HostCredentialIdentityReference,
		error: CredentialIdentityResolutionError
	) throws -> ResolvedIdentityConnection {
		guard reference.migrationState == .reversible else {
			throw error
		}
		return ResolvedIdentityConnection(
			host: host,
			identity: nil,
			payload: .legacyHostOwned
		)
	}
}
