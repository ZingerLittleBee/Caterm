import CloudKit
import CredentialSyncTypes
import Foundation
import ServerSyncClient
import SSHCommandBuilder

public enum CKRecordHostMapping {
	public static let recordType: CKRecord.RecordType = "Host"

	enum Field {
		// Metadata
		static let name = "name"
		static let hostname = "hostname"
		static let port = "port"
		static let username = "username"
		static let authType = "authType"
		static let metadataUpdatedAt = "metadataUpdatedAt"
		// Credential blob
		static let credentialBlobState = "credentialBlobState"
		static let credentialBlobRevision = "credentialBlobRevision"
		static let credentialKeyID = "credentialKeyID"
		static let credentialCryptoVersion = "credentialCryptoVersion"
		static let passwordCiphertext = "passwordCiphertext"
		static let passphraseCiphertext = "passphraseCiphertext"
		static let privateKeyCiphertext = "privateKeyCiphertext"
	}

	public struct DecodeResult {
		public let host: RemoteHost
		public let blob: CredentialBlob?
	}

	public enum DecodeError: Error, Equatable {
		case missingField(String)
	}

	/// Used by `.createRemote` only. Initializes metadata + seeds credential
	/// fields to "no payload yet" so the schema is fully populated from creation.
	public static func makeRecord(recordName: String,
	                              zoneID: CKRecordZone.ID,
	                              input: RemoteHostCreateInput) -> CKRecord {
		let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
		let rec = CKRecord(recordType: recordType, recordID: id)
		rec[Field.name] = input.name as CKRecordValue
		rec[Field.hostname] = input.hostname as CKRecordValue
		rec[Field.port] = input.port as CKRecordValue
		rec[Field.username] = input.username as CKRecordValue
		rec[Field.authType] = input.authType as CKRecordValue
		rec[Field.metadataUpdatedAt] = Date() as CKRecordValue
		rec[Field.credentialBlobState] = "none" as CKRecordValue
		rec[Field.credentialBlobRevision] = Int64(0) as CKRecordValue
		rec[Field.credentialCryptoVersion] = Int64(1) as CKRecordValue
		return rec
	}

	/// Used by `.updateRemote`. Mutates ONLY metadata fields on the existing
	/// CKRecord. Credential fields are intentionally untouched.
	public static func applyMetadata(into existing: CKRecord, from host: SSHHost) {
		existing[Field.name] = host.name as CKRecordValue
		existing[Field.hostname] = host.hostname as CKRecordValue
		existing[Field.port] = host.port as CKRecordValue
		existing[Field.username] = host.username as CKRecordValue
		existing[Field.metadataUpdatedAt] = host.updatedAt as CKRecordValue
	}

	/// Used by `.updateRemoteCredentials`. Mutates ONLY credential fields.
	/// Caller is responsible for the §Seed-before-credential-save step
	/// (writing `metadataUpdatedAt` once if it's nil) BEFORE calling this.
	public static func applyCredentialBlob(into existing: CKRecord, blob: CredentialBlob) {
		existing[Field.credentialBlobState] = blob.state.rawValue as CKRecordValue
		existing[Field.credentialBlobRevision] = blob.revision as CKRecordValue
		existing[Field.credentialCryptoVersion] = blob.cryptoVersion as CKRecordValue
		if let id = blob.keyID {
			existing[Field.credentialKeyID] = id as CKRecordValue
		} else {
			existing[Field.credentialKeyID] = nil
		}
		if let pw = blob.passwordCiphertext {
			existing[Field.passwordCiphertext] = pw as CKRecordValue
		} else {
			existing[Field.passwordCiphertext] = nil
		}
		if let pp = blob.passphraseCiphertext {
			existing[Field.passphraseCiphertext] = pp as CKRecordValue
		} else {
			existing[Field.passphraseCiphertext] = nil
		}
		if let pk = blob.privateKeyCiphertext {
			existing[Field.privateKeyCiphertext] = pk as CKRecordValue
		} else {
			existing[Field.privateKeyCiphertext] = nil
		}
	}

	public static func decode(_ rec: CKRecord) throws -> DecodeResult {
		guard let name = rec[Field.name] as? String else { throw DecodeError.missingField("name") }
		guard let hostname = rec[Field.hostname] as? String else { throw DecodeError.missingField("hostname") }
		guard let port = rec[Field.port] as? Int else { throw DecodeError.missingField("port") }
		guard let username = rec[Field.username] as? String else { throw DecodeError.missingField("username") }
		let authType = (rec[Field.authType] as? String) ?? "key"

		// Fallback chain: metadataUpdatedAt → modificationDate → creationDate
		// → .distantPast.
		let updatedAt: Date = (rec[Field.metadataUpdatedAt] as? Date)
			?? rec.modificationDate
			?? rec.creationDate
			?? .distantPast

		let host = RemoteHost(
			id: rec.recordID.recordName,
			name: name,
			hostname: hostname,
			port: port,
			username: username,
			authType: authType,
			createdAt: rec.creationDate ?? .distantPast,
			updatedAt: updatedAt
		)

		let blob: CredentialBlob?
		if let stateRaw = rec[Field.credentialBlobState] as? String,
		   let state = CredentialBlobState(rawValue: stateRaw),
		   state != .none {
			blob = CredentialBlob(
				state: state,
				revision: (rec[Field.credentialBlobRevision] as? Int64) ?? 0,
				keyID: rec[Field.credentialKeyID] as? String,
				cryptoVersion: (rec[Field.credentialCryptoVersion] as? Int64) ?? 1,
				passwordCiphertext: rec[Field.passwordCiphertext] as? Data,
				passphraseCiphertext: rec[Field.passphraseCiphertext] as? Data,
				privateKeyCiphertext: rec[Field.privateKeyCiphertext] as? Data
			)
		} else {
			blob = nil
		}
		return DecodeResult(host: host, blob: blob)
	}
}
