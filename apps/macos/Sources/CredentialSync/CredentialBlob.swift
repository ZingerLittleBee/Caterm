import Foundation

public enum CredentialBlobState: String, Sendable, Equatable {
	case none
	case payload
	case tombstone
}

public struct CredentialBlob: Sendable, Equatable {
	public var state: CredentialBlobState
	public var revision: Int64
	public var keyID: String?
	public var cryptoVersion: Int64
	public var passwordCiphertext: Data?
	public var passphraseCiphertext: Data?
	public var privateKeyCiphertext: Data?

	public init(
		state: CredentialBlobState,
		revision: Int64,
		keyID: String?,
		cryptoVersion: Int64 = 1,
		passwordCiphertext: Data? = nil,
		passphraseCiphertext: Data? = nil,
		privateKeyCiphertext: Data? = nil
	) {
		self.state = state
		self.revision = revision
		self.keyID = keyID
		self.cryptoVersion = cryptoVersion
		self.passwordCiphertext = passwordCiphertext
		self.passphraseCiphertext = passphraseCiphertext
		self.privateKeyCiphertext = privateKeyCiphertext
	}
}

public struct HostSecrets: Sendable, Equatable {
	public var password: Data?
	public var passphrase: Data?
	public var privateKeyBytes: Data?

	public init(password: Data? = nil, passphrase: Data? = nil, privateKeyBytes: Data? = nil) {
		self.password = password
		self.passphrase = passphrase
		self.privateKeyBytes = privateKeyBytes
	}

	public var anyPresent: Bool {
		password != nil || passphrase != nil || privateKeyBytes != nil
	}
}
