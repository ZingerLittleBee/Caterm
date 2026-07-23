import Foundation

/// Credential kinds shared by the app, the askpass helper, and Keychain storage.
public enum SSHCredentialKind: String, CaseIterable, Sendable {
	case password
	case keyPassphrase
}

/// Environment keys forming the cross-process contract with `caterm-askpass`.
public enum SSHCredentialEnvironmentKey: String, CaseIterable, Sendable {
	case askpassExecutable = "SSH_ASKPASS"
	case askpassRequirement = "SSH_ASKPASS_REQUIRE"
	case hostID = "CATERM_HOST_ID"
	case credentialKind = "CATERM_ASKPASS_KIND"
	case credentialService = "CATERM_ASKPASS_SERVICE"
	case credentialAccount = "CATERM_ASKPASS_ACCOUNT"
	case dataProtectionKeychain = "CATERM_ASKPASS_DATA_PROTECTION"
	case accessGroup = "CATERM_ACCESS_GROUP"
	case chain = "CATERM_CHAIN"
	case chainStatePath = "CATERM_CHAIN_STATE_PATH"
	case stuffMode = "CATERM_ASKPASS_STUFF"
	case stuffSecret = "CATERM_ASKPASS_SECRET"
}

/// Stable names shared across the main app, mobile app, and askpass executable.
public enum SSHCredentialContract {
	public static let keychainService = "com.caterm.host"
	public static let askpassRequiredValue = "force"
	public static let stuffModeEnabledValue = "1"
	public static let dataProtectionKeychainEnabledValue = "1"

	public static func account(hostID: UUID, kind: SSHCredentialKind) -> String {
		account(hostID: hostID.uuidString, kind: kind)
	}

	public static func account(hostID: String, kind: SSHCredentialKind) -> String {
		"\(hostID).\(kind.rawValue)"
	}

	public static func accountPrefix(hostID: UUID) -> String {
		"\(hostID.uuidString)."
	}

	public static func askpassEnvironment(executable: String) -> [(String, String)] {
		[
			(SSHCredentialEnvironmentKey.askpassExecutable.rawValue, executable),
			(SSHCredentialEnvironmentKey.askpassRequirement.rawValue, askpassRequiredValue),
		]
	}

	public static func askpassEnvironment(
		executable: String,
		hostID: UUID,
		kind: SSHCredentialKind
	) -> [(String, String)] {
		askpassEnvironment(executable: executable) + [
			(SSHCredentialEnvironmentKey.hostID.rawValue, hostID.uuidString),
			(SSHCredentialEnvironmentKey.credentialKind.rawValue, kind.rawValue),
		]
	}

	public static func askpassEnvironment(
		executable: String,
		kind: SSHCredentialKind,
		service: String,
		account: String,
		useDataProtectionKeychain: Bool
	) -> [(String, String)] {
		var environment = askpassEnvironment(executable: executable) + [
			(
				SSHCredentialEnvironmentKey.credentialKind.rawValue,
				kind.rawValue
			),
			(
				SSHCredentialEnvironmentKey.credentialService.rawValue,
				service
			),
			(
				SSHCredentialEnvironmentKey.credentialAccount.rawValue,
				account
			),
		]
		if useDataProtectionKeychain {
			environment.append((
				SSHCredentialEnvironmentKey.dataProtectionKeychain.rawValue,
				dataProtectionKeychainEnabledValue
			))
		}
		return environment
	}
}
