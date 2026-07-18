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
}
