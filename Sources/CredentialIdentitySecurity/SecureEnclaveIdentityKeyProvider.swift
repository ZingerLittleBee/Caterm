import CryptoKit
import Foundation
import LocalAuthentication
import Security

public struct SecureEnclaveIdentityKey: Sendable {
	public let privateKey: SecureEnclave.P256.Signing.PrivateKey
	public let dataRepresentation: Data
	public let publicKeyDER: Data

	public init(privateKey: SecureEnclave.P256.Signing.PrivateKey) {
		self.privateKey = privateKey
		self.dataRepresentation = privateKey.dataRepresentation
		self.publicKeyDER = privateKey.publicKey.derRepresentation
	}
}

public enum SecureEnclaveIdentityError: Error, Equatable {
	case unavailable
	case accessControlCreationFailed
}

public protocol SecureEnclaveIdentityKeyProviding: Sendable {
	var isAvailable: Bool { get }
	func create(localizedReason: String) throws -> SecureEnclaveIdentityKey
	func restore(
		dataRepresentation: Data,
		localizedReason: String
	) throws -> SecureEnclaveIdentityKey
}

public struct SystemSecureEnclaveIdentityKeyProvider:
	SecureEnclaveIdentityKeyProviding {
	public init() {}

	public var isAvailable: Bool {
		#if targetEnvironment(simulator)
		false
		#else
		SecureEnclave.isAvailable
		#endif
	}

	public func create(
		localizedReason: String
	) throws -> SecureEnclaveIdentityKey {
		guard isAvailable else {
			throw SecureEnclaveIdentityError.unavailable
		}
		var accessControlError: Unmanaged<CFError>?
		guard let accessControl = SecAccessControlCreateWithFlags(
			nil,
			kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
			[.privateKeyUsage, .userPresence],
			&accessControlError
		) else {
			throw SecureEnclaveIdentityError.accessControlCreationFailed
		}
		let context = LAContext()
		context.localizedReason = localizedReason
		let key = try SecureEnclave.P256.Signing.PrivateKey(
			compactRepresentable: true,
			accessControl: accessControl,
			authenticationContext: context
		)
		return SecureEnclaveIdentityKey(privateKey: key)
	}

	public func restore(
		dataRepresentation: Data,
		localizedReason: String
	) throws -> SecureEnclaveIdentityKey {
		guard isAvailable else {
			throw SecureEnclaveIdentityError.unavailable
		}
		let context = LAContext()
		context.localizedReason = localizedReason
		let key = try SecureEnclave.P256.Signing.PrivateKey(
			dataRepresentation: dataRepresentation,
			authenticationContext: context
		)
		return SecureEnclaveIdentityKey(privateKey: key)
	}
}
