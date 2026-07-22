import CatermMobileTerminal
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
		}
	}
}

public enum MobileAuthenticationPlanResult: Equatable, Sendable {
	case available(SSHAuthPlan)
	case unavailable(MobileCredentialUnavailableReason)
}

/// Resolves the public mobile authentication plan away from the main actor.
/// Host-key trust is intentionally not part of this type; each receiving
/// device evaluates its own Known Hosts database when transport starts.
public actor MobileAuthenticationPlanProvider {
	private let materialStore: SessionCredentialMaterialStore

	public init(materialStore: SessionCredentialMaterialStore) {
		self.materialStore = materialStore
	}

	public func resolve(
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
		} catch KeychainError.interactionNotAllowed {
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
			return .available(SSHAuthPlan.make(
				host: host,
				password: password,
				keyBlob: nil,
				passphrase: nil
			))
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
			return .available(SSHAuthPlan.make(
				host: host,
				password: nil,
				keyBlob: keyBlob,
				passphrase: passphrase
			))
		case .agent:
			return .available(SSHAuthPlan.make(
				host: host,
				password: nil,
				keyBlob: nil,
				passphrase: nil
			))
		}
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
