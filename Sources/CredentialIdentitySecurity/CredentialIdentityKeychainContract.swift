import CredentialIdentityStore
import Foundation

public enum CredentialIdentityKeychainContract {
	public static let service =
		"com.caterm.app.credential-identities"

	public enum SecretKind: String, Sendable {
		case password
		case passphrase
		case secureEnclaveKey
	}

	public static func account(
		materialID: CredentialMaterialID,
		kind: SecretKind
	) -> String {
		"identity.\(materialID.rawValue.uuidString).\(kind.rawValue)"
	}
}
