import Crypto
import CryptoExtras
import Foundation

/// Errors surfaced by envelope sealing/opening. `wrongPassphrase` and
/// `corruptArchive` are deliberately distinct so import UI can tell the
/// user which problem they actually have (the key-validation block makes
/// the distinction possible — a single AEAD blob cannot).
public enum BackupArchiveError: Error, Equatable {
	case wrongPassphrase
	case corruptArchive(reason: String)
	case unsupportedFormatVersion(Int)
	case unsupportedAlgorithm(String)
}

/// scrypt cost parameters, embedded in the envelope so a decryptor needs
/// only the file and the passphrase (self-describing header — ADR 0002).
public struct ScryptParameters: Codable, Equatable, Sendable {
	public var name: String
	/// CPU/memory cost (scrypt N). Must be a power of two.
	public var n: Int
	/// Block size (scrypt r).
	public var r: Int
	/// Parallelism (scrypt p).
	public var p: Int
	public var salt: Data

	public init(name: String, n: Int, r: Int, p: Int, salt: Data) {
		self.name = name
		self.n = n
		self.r = r
		self.p = p
		self.salt = salt
	}

	/// OWASP-recommended cost tier (~128 MiB transient, a few hundred ms
	/// on Apple Silicon) with a fresh 32-byte salt.
	public static func fresh() -> ScryptParameters {
		ScryptParameters(name: "scrypt", n: 1 << 17, r: 8, p: 1,
		                 salt: Data.random(count: 32))
	}
}

/// The `.catermbackup` file: a self-describing JSON envelope holding one
/// AES-256-GCM-sealed payload plus a small key-validation block. The
/// canonicalized header is fed to both seals as AAD, so tampering with
/// the KDF parameters (cost-downgrade attacks) breaks authentication —
/// see ADR 0002.
public struct BackupEnvelope: Codable, Equatable {
	public var formatVersion: Int
	public var kdf: ScryptParameters
	public var cipher: String
	public var keyValidation: SealedBlob
	/// Payload nonce (12 bytes).
	public var nonce: Data
	/// Payload ciphertext with the 16-byte GCM tag appended.
	public var ciphertext: Data

	public struct SealedBlob: Codable, Equatable {
		public var nonce: Data
		public var ciphertext: Data
	}
}

/// Seal/open for `.catermbackup` archives.
public enum BackupArchive {
	public static let fileExtension = "catermbackup"
	public static let formatVersion = 1
	public static let cipherName = "aes-256-gcm"
	public static let minimumPassphraseLength = 8

	/// Fixed plaintext the key-validation block seals. Opening it with a
	/// wrongly-derived key fails GCM authentication → `wrongPassphrase`.
	static let keyValidationPlaintext = Data("caterm-backup-key-validation".utf8)

	// MARK: Seal

	/// Encrypt `payload` (an encoded `BackupPayload`) under `passphrase`
	/// and return the JSON envelope bytes to write to disk.
	public static func seal(
		payload: Data,
		passphrase: String,
		kdf: ScryptParameters = .fresh()
	) throws -> Data {
		let key = try deriveKey(passphrase: passphrase, kdf: kdf)
		let aad = headerAAD(formatVersion: formatVersion, kdf: kdf)

		let validation = try AES.GCM.seal(
			keyValidationPlaintext, using: key,
			authenticating: aad + Data("|key-validation".utf8)
		)
		let sealed = try AES.GCM.seal(
			payload, using: key,
			authenticating: aad + Data("|payload".utf8)
		)

		let envelope = BackupEnvelope(
			formatVersion: formatVersion,
			kdf: kdf,
			cipher: cipherName,
			keyValidation: .init(nonce: Data(validation.nonce),
			                     ciphertext: validation.ciphertext + validation.tag),
			nonce: Data(sealed.nonce),
			ciphertext: sealed.ciphertext + sealed.tag
		)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		return try encoder.encode(envelope)
	}

	// MARK: Open

	/// Decrypt an envelope produced by `seal`. Throws `wrongPassphrase`
	/// when the key-validation block fails to open, `corruptArchive` when
	/// the file is malformed or the payload fails authentication despite
	/// a correct passphrase.
	public static func open(_ envelopeData: Data, passphrase: String) throws -> Data {
		let envelope: BackupEnvelope
		do {
			envelope = try JSONDecoder().decode(BackupEnvelope.self, from: envelopeData)
		} catch {
			throw BackupArchiveError.corruptArchive(reason: "not a Caterm backup file")
		}
		guard envelope.formatVersion == formatVersion else {
			throw BackupArchiveError.unsupportedFormatVersion(envelope.formatVersion)
		}
		guard envelope.cipher == cipherName else {
			throw BackupArchiveError.unsupportedAlgorithm(envelope.cipher)
		}
		guard envelope.kdf.name == "scrypt" else {
			throw BackupArchiveError.unsupportedAlgorithm(envelope.kdf.name)
		}
		try validateBounds(envelope.kdf)

		let key = try deriveKey(passphrase: passphrase, kdf: envelope.kdf)
		let aad = headerAAD(formatVersion: envelope.formatVersion, kdf: envelope.kdf)

		do {
			let box = try sealedBox(nonce: envelope.keyValidation.nonce,
			                        ciphertextAndTag: envelope.keyValidation.ciphertext)
			_ = try AES.GCM.open(box, using: key,
			                     authenticating: aad + Data("|key-validation".utf8))
		} catch {
			throw BackupArchiveError.wrongPassphrase
		}

		do {
			let box = try sealedBox(nonce: envelope.nonce,
			                        ciphertextAndTag: envelope.ciphertext)
			return try AES.GCM.open(box, using: key,
			                        authenticating: aad + Data("|payload".utf8))
		} catch {
			throw BackupArchiveError.corruptArchive(reason: "payload failed authentication")
		}
	}

	// MARK: Passphrase helpers

	/// Cryptographically random, transcription-friendly passphrase for
	/// the "Generate" button: 4 groups of 5 chars from an unambiguous
	/// charset (no 0/O/1/l/I) ≈ 116 bits of entropy.
	public static func randomPassphrase() -> String {
		let charset = Array("23456789abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ")
		var rng = SystemRandomNumberGenerator()
		let groups = (0..<4).map { _ in
			String((0..<5).map { _ in charset.randomElement(using: &rng)! })
		}
		return groups.joined(separator: "-")
	}

	// MARK: Internals

	/// Canonical header bytes used as AAD. Field order and format are
	/// frozen for formatVersion 1 (ADR 0002); any change requires a new
	/// format version. Includes a domain-separation label (age's lesson).
	static func headerAAD(formatVersion: Int, kdf: ScryptParameters) -> Data {
		Data(
			"caterm-backup|v\(formatVersion)|\(kdf.name)|n=\(kdf.n)|r=\(kdf.r)|p=\(kdf.p)|salt=\(kdf.salt.base64EncodedString())|\(cipherName)"
				.utf8
		)
	}

	private static func deriveKey(passphrase: String, kdf: ScryptParameters) throws -> SymmetricKey {
		// NFC-normalize so the same passphrase typed on different
		// platforms/keyboards derives the same key.
		let normalized = passphrase.precomposedStringWithCanonicalMapping
		return try KDF.Scrypt.deriveKey(
			from: Data(normalized.utf8),
			salt: kdf.salt,
			outputByteCount: 32,
			rounds: kdf.n,
			blockSize: kdf.r,
			parallelism: kdf.p
		)
	}

	/// Bounds guard: a malicious envelope must not be able to turn the
	/// KDF into a memory/CPU bomb, and degenerate parameters must not
	/// silently weaken derivation.
	private static func validateBounds(_ kdf: ScryptParameters) throws {
		guard kdf.n >= 1 << 14, kdf.n <= 1 << 22, kdf.n.nonzeroBitCount == 1,
		      (1...32).contains(kdf.r),
		      (1...8).contains(kdf.p),
		      (16...64).contains(kdf.salt.count) else {
			throw BackupArchiveError.corruptArchive(reason: "KDF parameters out of range")
		}
	}

	private static func sealedBox(nonce: Data, ciphertextAndTag: Data) throws -> AES.GCM.SealedBox {
		guard ciphertextAndTag.count >= 16 else {
			throw BackupArchiveError.corruptArchive(reason: "truncated ciphertext")
		}
		let tagStart = ciphertextAndTag.index(ciphertextAndTag.endIndex, offsetBy: -16)
		return try AES.GCM.SealedBox(
			nonce: AES.GCM.Nonce(data: nonce),
			ciphertext: ciphertextAndTag[..<tagStart],
			tag: ciphertextAndTag[tagStart...]
		)
	}
}

extension Data {
	static func random(count: Int) -> Data {
		var rng = SystemRandomNumberGenerator()
		var bytes = [UInt8]()
		bytes.reserveCapacity(count)
		for _ in 0..<count { bytes.append(UInt8(truncatingIfNeeded: rng.next())) }
		return Data(bytes)
	}
}
