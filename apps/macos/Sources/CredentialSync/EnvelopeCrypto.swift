import CryptoKit
import Foundation

public enum EnvelopeCrypto {
    public enum FieldKind: String, Sendable {
        case password
        case passphrase
        case privateKey
    }

    public static let schemaVersion: Int = 1

    /// Spec §Cryptography: AAD = "serverId|fieldKind|revision|schemaVersion"
    public static func aad(serverId: String, fieldKind: FieldKind, revision: Int64) -> Data {
        Data("\(serverId)|\(fieldKind.rawValue)|\(revision)|\(schemaVersion)".utf8)
    }

    public enum Error: Swift.Error, Equatable {
        case decryptionFailed
    }

    /// Returns `SealedBox.combined` (12-byte nonce ‖ ciphertext ‖ 16-byte tag).
    public static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = box.combined else {
            throw Error.decryptionFailed  // unreachable in practice (AES.GCM always returns combined for 12-byte nonces)
        }
        return combined
    }

    public static func open(_ sealed: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: sealed)
        do {
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw Error.decryptionFailed
        }
    }
}
