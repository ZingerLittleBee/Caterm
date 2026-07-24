import Crypto
import Foundation
import NIOSSH

public enum MobileSSHPrivateKeyError: Error, Equatable, Sendable {
	case invalidEncoding
	case encryptedKeyUnsupported
	case unsupportedKeyType(String)
	case invalidKeyMaterial
}

extension MobileSSHPrivateKeyError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .invalidEncoding:
			"The private key is not a valid OpenSSH key."
		case .encryptedKeyUnsupported:
			"Encrypted private keys are not supported by the mobile SSH transport."
		case .unsupportedKeyType(let type):
			"The mobile SSH transport does not support private key type \(type)."
		case .invalidKeyMaterial:
			"The OpenSSH private key contains invalid key material."
		}
	}
}

enum OpenSSHPrivateKeyParser {
	static func parse(
		_ data: Data,
		passphrase: String?
	) throws -> NIOSSHPrivateKey {
		guard let text = String(data: data, encoding: .utf8) else {
			throw MobileSSHPrivateKeyError.invalidEncoding
		}
		let payload = text
			.replacingOccurrences(
				of: "-----BEGIN OPENSSH PRIVATE KEY-----",
				with: ""
			)
			.replacingOccurrences(
				of: "-----END OPENSSH PRIVATE KEY-----",
				with: ""
			)
			.components(separatedBy: .whitespacesAndNewlines)
			.joined()
		guard let decoded = Data(base64Encoded: payload) else {
			throw MobileSSHPrivateKeyError.invalidEncoding
		}

		var reader = OpenSSHKeyReader(data: decoded)
		guard try reader.readBytes(count: 15) == Data("openssh-key-v1\0".utf8) else {
			throw MobileSSHPrivateKeyError.invalidEncoding
		}
		let cipher = try reader.readString()
		let kdf = try reader.readString()
		_ = try reader.readData()
		guard cipher == "none", kdf == "none", passphrase == nil else {
			throw MobileSSHPrivateKeyError.encryptedKeyUnsupported
		}
		guard try reader.readUInt32() == 1 else {
			throw MobileSSHPrivateKeyError.invalidEncoding
		}
		_ = try reader.readData()
		var privateReader = OpenSSHKeyReader(data: try reader.readData())
		let check = try privateReader.readUInt32()
		guard try privateReader.readUInt32() == check else {
			throw MobileSSHPrivateKeyError.invalidKeyMaterial
		}
		let keyType = try privateReader.readString()
		guard keyType == "ssh-ed25519" else {
			throw MobileSSHPrivateKeyError.unsupportedKeyType(keyType)
		}
		let publicKey = try privateReader.readData()
		let privateAndPublic = try privateReader.readData()
		guard privateAndPublic.count == 64,
			privateAndPublic.suffix(32) == publicKey else {
			throw MobileSSHPrivateKeyError.invalidKeyMaterial
		}
		let privateKey = try Curve25519.Signing.PrivateKey(
			rawRepresentation: privateAndPublic.prefix(32)
		)
		return NIOSSHPrivateKey(ed25519Key: privateKey)
	}
}

private struct OpenSSHKeyReader {
	private let data: Data
	private var offset = 0

	init(data: Data) {
		self.data = data
	}

	mutating func readUInt32() throws -> UInt32 {
		let bytes = try readBytes(count: 4)
		return bytes.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
	}

	mutating func readData() throws -> Data {
		let count = try readUInt32()
		guard let length = Int(exactly: count) else {
			throw MobileSSHPrivateKeyError.invalidEncoding
		}
		return try readBytes(count: length)
	}

	mutating func readString() throws -> String {
		guard let string = String(data: try readData(), encoding: .utf8) else {
			throw MobileSSHPrivateKeyError.invalidEncoding
		}
		return string
	}

	mutating func readBytes(count: Int) throws -> Data {
		guard count >= 0, offset <= data.count - count else {
			throw MobileSSHPrivateKeyError.invalidEncoding
		}
		defer { offset += count }
		return data.subdata(in: offset..<(offset + count))
	}
}
