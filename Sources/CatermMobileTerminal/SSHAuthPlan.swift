import CredentialIdentitySecurity
import Foundation
import SSHCommandBuilder

public struct SSHAuthPlan: Equatable, Sendable {
	public enum Attempt: Sendable {
		case password(String)
		case privateKey(blob: Data, passphrase: String?)
		case certifiedPrivateKey(
			blob: Data,
			passphrase: String?,
			publicCertificate: Data
		)
		case secureEnclaveP256(SecureEnclaveIdentityKey)
		case keyboardInteractive
	}

	public enum Missing: Equatable, Sendable {
		case password
		case passphrase
		case keyBlob
	}

	public let attempts: [Attempt]
	public let missing: Missing?

	public init(attempts: [Attempt], missing: Missing?) {
		self.attempts = attempts
		self.missing = missing
	}

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

extension SSHAuthPlan.Attempt: Equatable {
	public static func == (
		lhs: SSHAuthPlan.Attempt,
		rhs: SSHAuthPlan.Attempt
	) -> Bool {
		switch (lhs, rhs) {
		case (.password(let lhs), .password(let rhs)):
			lhs == rhs
		case (
			.privateKey(let lhsBlob, let lhsPassphrase),
			.privateKey(let rhsBlob, let rhsPassphrase)
		):
			lhsBlob == rhsBlob && lhsPassphrase == rhsPassphrase
		case (
			.certifiedPrivateKey(
				let lhsBlob,
				let lhsPassphrase,
				let lhsCertificate
			),
			.certifiedPrivateKey(
				let rhsBlob,
				let rhsPassphrase,
				let rhsCertificate
			)
		):
			lhsBlob == rhsBlob
				&& lhsPassphrase == rhsPassphrase
				&& lhsCertificate == rhsCertificate
		case (
			.secureEnclaveP256(let lhs),
			.secureEnclaveP256(let rhs)
		):
			lhs.publicKeyDER == rhs.publicKeyDER
		case (.keyboardInteractive, .keyboardInteractive):
			true
		default:
			false
		}
	}
}
