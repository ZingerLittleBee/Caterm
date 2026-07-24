import Foundation

public struct CredentialIdentitySyncRecord: Equatable, Sendable {
	public var identity: CredentialIdentity
	public var keyID: String?
	public var cryptoVersion: Int64
	public var passwordCiphertext: Data?
	public var passphraseCiphertext: Data?
	public var privateKeyCiphertext: Data?

	public init(
		identity: CredentialIdentity,
		keyID: String? = nil,
		cryptoVersion: Int64 = 1,
		passwordCiphertext: Data? = nil,
		passphraseCiphertext: Data? = nil,
		privateKeyCiphertext: Data? = nil
	) {
		self.identity = identity
		self.keyID = keyID
		self.cryptoVersion = cryptoVersion
		self.passwordCiphertext = passwordCiphertext
		self.passphraseCiphertext = passphraseCiphertext
		self.privateKeyCiphertext = privateKeyCiphertext
	}
}

public protocol CredentialIdentitySyncClient: Sendable {
	func listCredentialIdentities() async throws
		-> [CredentialIdentitySyncRecord]
	func upsertCredentialIdentity(
		_ record: CredentialIdentitySyncRecord
	) async throws -> String
	func deleteCredentialIdentity(id: String) async throws
}
