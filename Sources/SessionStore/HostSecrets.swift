import Foundation

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
