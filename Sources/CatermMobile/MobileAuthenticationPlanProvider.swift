import CatermMobileTerminal
import CredentialIdentityRuntime
import CredentialIdentitySecurity
import CredentialIdentityStore
import CredentialSyncStore
import Foundation
import KeychainStore
import SessionStore
import SSHCommandBuilder

public enum MobileCredentialUnavailableReason: Error, Equatable, Sendable {
	case missingPassword
	case missingPassphrase
	case syncMasterKeyPending(keyID: String?)
	case deviceBoundPrivateKeyUnavailable
	case keychainLocked
	case credentialReadFailed
	case missingIdentity
}

extension MobileCredentialUnavailableReason: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .missingPassword:
			"The password is not available on this device."
		case .missingPassphrase:
			"The private-key passphrase is not available on this device."
		case .syncMasterKeyPending:
			"Encrypted credentials are waiting for the iCloud Keychain sync key."
		case .deviceBoundPrivateKeyUnavailable:
			"This private key is stored only on another device."
		case .keychainLocked:
			"Unlock this device to access the saved credential."
		case .credentialReadFailed:
			"The saved credential could not be read."
		case .missingIdentity:
			"The selected credential identity is unavailable."
		}
	}
}

public struct MobilePreparedAuthentication: Equatable, Sendable {
	public let host: SSHHost
	public let plan: SSHAuthPlan

	public init(host: SSHHost, plan: SSHAuthPlan) {
		self.host = host
		self.plan = plan
	}
}

public enum MobileAuthenticationPlanResult: Equatable, Sendable {
	case available(MobilePreparedAuthentication)
	case unavailable(MobileCredentialUnavailableReason)
}

/// Resolves the public mobile authentication plan away from the main actor.
/// Host-key trust is intentionally not part of this type; each receiving
/// device evaluates its own Known Hosts database when transport starts.
public actor MobileAuthenticationPlanProvider {
	private let materialStore: SessionCredentialMaterialStore
	private let identityMaterialStore: CredentialIdentityMaterialStore?
	private let identityStore: CredentialIdentityStore?
	private let identity:
		@Sendable (UUID) async -> CredentialIdentity?

	public init(
		materialStore: SessionCredentialMaterialStore,
		identityMaterialStore:
			CredentialIdentityMaterialStore? = nil,
		identityStore: CredentialIdentityStore? = nil,
		identity:
			@escaping @Sendable (UUID) async
				-> CredentialIdentity? = { _ in nil }
	) {
		self.materialStore = materialStore
		self.identityMaterialStore = identityMaterialStore
		self.identityStore = identityStore
		self.identity = identity
	}

	public func resolve(
		host: SSHHost,
		credentialSyncState: CredentialSyncState
	) async -> MobileAuthenticationPlanResult {
		if let reference = host.credentialIdentity {
			let result = await resolveIdentity(
				host: host,
				identityID: reference.identityID,
				credentialSyncState: credentialSyncState
			)
			if reference.migrationState == .reversible,
			   case .unavailable = result {
				return await resolveLegacy(
					host: host,
					credentialSyncState: credentialSyncState
				)
			}
			return result
		}
		return await resolveLegacy(
			host: host,
			credentialSyncState: credentialSyncState
		)
	}

	private func resolveLegacy(
		host: SSHHost,
		credentialSyncState: CredentialSyncState
	) async -> MobileAuthenticationPlanResult {
		do {
			let selection: CredentialMaterialSelection = switch host.credential {
			case .password:
				.password
			case .keyFile:
				[.passphrase, .managedPrivateKey]
			case .agent:
				[]
			}
			let material = try await materialStore.snapshot(
				for: host.id,
				selecting: selection,
				interaction: .userInitiated
			)
			return resolve(
				host: host,
				material: material,
				credentialSyncState: credentialSyncState
			)
		} catch KeychainError.interactionNotAllowed,
		        IdentityKeychainError.interactionNotAllowed {
			return .unavailable(.keychainLocked)
		} catch {
			return .unavailable(.credentialReadFailed)
		}
	}

	private func resolve(
		host: SSHHost,
		material: StoredCredentialMaterialSnapshot,
		credentialSyncState: CredentialSyncState
	) -> MobileAuthenticationPlanResult {
		switch host.credential {
		case .password:
			guard let password = decode(material.password) else {
				return unavailableForMissingMaterial(
					fallback: .missingPassword,
					state: credentialSyncState
				)
			}
			return available(
				host: host,
				plan: SSHAuthPlan.make(
					host: host,
					password: password,
					keyBlob: nil,
					passphrase: nil
				)
			)
		case let .keyFile(path, hasPassphrase):
			let keyBlob = material.managedPrivateKey
				?? FileManager.default.contents(
					atPath: (path as NSString).expandingTildeInPath
				)
			guard let keyBlob else {
				return unavailableForMissingMaterial(
					fallback: .deviceBoundPrivateKeyUnavailable,
					state: credentialSyncState
				)
			}
			let passphrase = decode(material.passphrase)
			guard !hasPassphrase || passphrase != nil else {
				return unavailableForMissingMaterial(
					fallback: .missingPassphrase,
					state: credentialSyncState
				)
			}
			return available(
				host: host,
				plan: SSHAuthPlan.make(
					host: host,
					password: nil,
					keyBlob: keyBlob,
					passphrase: passphrase
				)
			)
		case .agent:
			return available(
				host: host,
				plan: SSHAuthPlan.make(
					host: host,
					password: nil,
					keyBlob: nil,
					passphrase: nil
				)
			)
		}
	}

	private func resolveIdentity(
		host: SSHHost,
		identityID: UUID,
		credentialSyncState: CredentialSyncState
	) async -> MobileAuthenticationPlanResult {
		guard let identityStore else {
			return await resolveIdentityWithinTransaction(
				host: host,
				identityID: identityID,
				credentialSyncState: credentialSyncState
			)
		}
		do {
			return try await identityStore.withTransaction {
				await self.resolveIdentityWithinTransaction(
					host: host,
					identityID: identityID,
					credentialSyncState: credentialSyncState
				)
			}
		} catch {
			return .unavailable(.credentialReadFailed)
		}
	}

	private func resolveIdentityWithinTransaction(
		host: SSHHost,
		identityID: UUID,
		credentialSyncState: CredentialSyncState
	) async -> MobileAuthenticationPlanResult {
		guard let identityMaterialStore,
		      let identity = await identity(identityID) else {
			return .unavailable(.missingIdentity)
		}
		do {
			let material = try await identityMaterialStore.snapshot(
				for: identity
			)
			let resolved =
				try CredentialIdentityConnectionResolver.resolve(
					host: host,
					identities: [identity],
					material: material
				)
			switch resolved.payload {
			case .legacyHostOwned:
				return .unavailable(.missingIdentity)
			case .password(let password):
				guard let password = decode(password) else {
					return unavailableForMissingMaterial(
						fallback: .missingPassword,
						state: credentialSyncState
					)
				}
				return available(
					host: resolved.host,
					plan: SSHAuthPlan(
						attempts: [.password(password)],
						missing: nil
					)
				)
			case .managedKey(
				let privateKey,
				let passphraseData,
				let publicCertificate
			):
				let passphrase = decode(passphraseData)
				let attempt: SSHAuthPlan.Attempt
				if let publicCertificate {
					attempt = .certifiedPrivateKey(
						blob: privateKey,
						passphrase: passphrase,
						publicCertificate: publicCertificate
					)
				} else {
					attempt = .privateKey(
						blob: privateKey,
						passphrase: passphrase
					)
				}
				return available(
					host: resolved.host,
					plan: SSHAuthPlan(
						attempts: [attempt],
						missing: nil
					)
				)
			case .secureEnclaveP256:
				let key = try await identityMaterialStore
					.secureEnclaveKey(
						for: identity,
						localizedReason:
							"Use \(identity.name) to authenticate this SSH connection."
					)
				return available(
					host: resolved.host,
					plan: SSHAuthPlan(
						attempts: [.secureEnclaveP256(key)],
						missing: nil
					)
				)
			}
		} catch IdentityKeychainError.interactionNotAllowed {
			return .unavailable(.keychainLocked)
		} catch CredentialIdentityResolutionError
			.secureEnclaveUnavailable {
			return .unavailable(
				.deviceBoundPrivateKeyUnavailable
			)
		} catch CredentialIdentityMaterialStoreError
			.materialUnavailable {
			return .unavailable(
				.deviceBoundPrivateKeyUnavailable
			)
		} catch {
			return .unavailable(.credentialReadFailed)
		}
	}

	private func available(
		host: SSHHost,
		plan: SSHAuthPlan
	) -> MobileAuthenticationPlanResult {
		.available(
			MobilePreparedAuthentication(
				host: host,
				plan: plan
			)
		)
	}

	private func unavailableForMissingMaterial(
		fallback: MobileCredentialUnavailableReason,
		state: CredentialSyncState
	) -> MobileAuthenticationPlanResult {
		if case let .waitingForKey(keyID) = state {
			return .unavailable(.syncMasterKeyPending(keyID: keyID))
		}
		return .unavailable(fallback)
	}

	private func decode(_ data: Data?) -> String? {
		guard let data else { return nil }
		return String(data: data, encoding: .utf8)
	}
}
