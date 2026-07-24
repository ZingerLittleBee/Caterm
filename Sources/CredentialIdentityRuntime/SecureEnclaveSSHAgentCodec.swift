import CredentialIdentitySecurity
import CryptoKit
import Foundation

public protocol P256SSHAgentSigning: Sendable {
	var publicKeyX963Representation: Data { get }
	func signature(for data: Data) throws -> Data
}

public struct SecureEnclaveP256SSHAgentSigner: P256SSHAgentSigning {
	private let key: SecureEnclaveIdentityKey

	public init(key: SecureEnclaveIdentityKey) {
		self.key = key
	}

	public var publicKeyX963Representation: Data {
		key.privateKey.publicKey.x963Representation
	}

	public func signature(for data: Data) throws -> Data {
		try key.privateKey.signature(for: data).rawRepresentation
	}
}

public enum SecureEnclaveSSHAgentCodecError: Error, Equatable {
	case malformedMessage
	case unsupportedRequest(UInt8)
	case unexpectedKey
	case unsupportedFlags(UInt32)
	case invalidPublicKey
	case invalidSignature
}

public enum SecureEnclaveSSHAgentCodec {
	public static let maximumMessageSize = 256 * 1024

	private static let failure: UInt8 = 5
	private static let requestIdentities: UInt8 = 11
	private static let identitiesAnswer: UInt8 = 12
	private static let signRequest: UInt8 = 13
	private static let signResponse: UInt8 = 14
	private static let algorithm = "ecdsa-sha2-nistp256"
	private static let curve = "nistp256"

	public static func response(
		to message: Data,
		signer: any P256SSHAgentSigning,
		comment: String
	) throws -> Data {
		guard message.count <= maximumMessageSize else {
			throw SecureEnclaveSSHAgentCodecError.malformedMessage
		}
		var reader = SSHAgentDataReader(data: message)
		let type = try reader.readByte()
		switch type {
		case requestIdentities:
			guard reader.isAtEnd else {
				throw SecureEnclaveSSHAgentCodecError.malformedMessage
			}
			var response = Data([identitiesAnswer])
			response.appendUInt32(1)
			response.appendSSHString(
				try publicKeyBlob(
					x963Representation:
						signer.publicKeyX963Representation
				)
			)
			response.appendSSHString(Data(comment.utf8))
			return response

		case signRequest:
			let requestedKey = try reader.readSSHString()
			let payload = try reader.readSSHString()
			let flags = try reader.readUInt32()
			guard reader.isAtEnd else {
				throw SecureEnclaveSSHAgentCodecError.malformedMessage
			}
			guard flags == 0 else {
				throw SecureEnclaveSSHAgentCodecError
					.unsupportedFlags(flags)
			}
			guard requestedKey == (try publicKeyBlob(
				x963Representation:
					signer.publicKeyX963Representation
			)) else {
				throw SecureEnclaveSSHAgentCodecError.unexpectedKey
			}
			let rawSignature = try signer.signature(for: payload)
			guard rawSignature.count == 64 else {
				throw SecureEnclaveSSHAgentCodecError.invalidSignature
			}
			let r = rawSignature.prefix(32)
			let s = rawSignature.suffix(32)
			var ecdsaSignature = Data()
			ecdsaSignature.appendSSHString(mpint(r))
			ecdsaSignature.appendSSHString(mpint(s))
			var signatureBlob = Data()
			signatureBlob.appendSSHString(Data(algorithm.utf8))
			signatureBlob.appendSSHString(ecdsaSignature)
			var response = Data([signResponse])
			response.appendSSHString(signatureBlob)
			return response

		default:
			throw SecureEnclaveSSHAgentCodecError.unsupportedRequest(type)
		}
	}

	public static func failureResponse() -> Data {
		Data([failure])
	}

	public static func publicKeyBlob(
		x963Representation: Data
	) throws -> Data {
		guard x963Representation.count == 65,
		      x963Representation.first == 0x04 else {
			throw SecureEnclaveSSHAgentCodecError.invalidPublicKey
		}
		var blob = Data()
		blob.appendSSHString(Data(algorithm.utf8))
		blob.appendSSHString(Data(curve.utf8))
		blob.appendSSHString(x963Representation)
		return blob
	}

	private static func mpint<T: DataProtocol>(_ value: T) -> Data {
		var bytes = Data(value)
		while bytes.first == 0 {
			bytes.removeFirst()
		}
		guard let first = bytes.first else { return Data() }
		if first & 0x80 != 0 {
			bytes.insert(0, at: bytes.startIndex)
		}
		return bytes
	}
}

private struct SSHAgentDataReader {
	let data: Data
	private(set) var offset = 0

	var isAtEnd: Bool {
		offset == data.count
	}

	mutating func readByte() throws -> UInt8 {
		guard offset < data.count else {
			throw SecureEnclaveSSHAgentCodecError.malformedMessage
		}
		defer { offset += 1 }
		return data[offset]
	}

	mutating func readUInt32() throws -> UInt32 {
		guard data.count - offset >= 4 else {
			throw SecureEnclaveSSHAgentCodecError.malformedMessage
		}
		let value = data[offset..<(offset + 4)].reduce(UInt32(0)) {
			($0 << 8) | UInt32($1)
		}
		offset += 4
		return value
	}

	mutating func readSSHString() throws -> Data {
		let length = Int(try readUInt32())
		guard length <= SecureEnclaveSSHAgentCodec.maximumMessageSize,
		      length <= data.count - offset else {
			throw SecureEnclaveSSHAgentCodecError.malformedMessage
		}
		defer { offset += length }
		return data.subdata(in: offset..<(offset + length))
	}
}

extension Data {
	fileprivate mutating func appendUInt32(_ value: UInt32) {
		append(UInt8((value >> 24) & 0xff))
		append(UInt8((value >> 16) & 0xff))
		append(UInt8((value >> 8) & 0xff))
		append(UInt8(value & 0xff))
	}

	fileprivate mutating func appendSSHString(_ value: Data) {
		appendUInt32(UInt32(value.count))
		append(value)
	}
}
