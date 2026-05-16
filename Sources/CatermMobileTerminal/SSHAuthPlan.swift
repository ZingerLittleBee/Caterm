import Foundation
import SSHCommandBuilder

public struct SSHAuthPlan: Equatable {
	public enum Attempt: Equatable {
		case password(String)
		case privateKey(blob: Data, passphrase: String?)
		case keyboardInteractive
	}

	public enum Missing: Equatable {
		case password
		case passphrase
		case keyBlob
	}

	public let attempts: [Attempt]
	public let missing: Missing?

	public static func make(
		host: SSHHost,
		password: String?,
		keyBlob: Data?,
		passphrase: String?
	) -> SSHAuthPlan {
		switch host.credential {
		case .password:
			if let password {
				return SSHAuthPlan(attempts: [.password(password)], missing: nil)
			}
			return SSHAuthPlan(attempts: [], missing: .password)
		case .keyFile(_, let hasPassphrase):
			guard let keyBlob else {
				return SSHAuthPlan(attempts: [], missing: .keyBlob)
			}
			if hasPassphrase, passphrase == nil {
				return SSHAuthPlan(attempts: [], missing: .passphrase)
			}
			return SSHAuthPlan(
				attempts: [.privateKey(blob: keyBlob, passphrase: passphrase)],
				missing: nil)
		case .agent:
			return SSHAuthPlan(attempts: [.keyboardInteractive], missing: nil)
		}
	}
}
