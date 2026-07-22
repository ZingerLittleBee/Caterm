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
		static let jumpHostServerId = "jumpHostServerId"
		static let forwards = "forwards"
		static let icon = "icon"
		static let organization = "organization"
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
		rec[Field.metadataUpdatedAt] = input.metadataUpdatedAt as CKRecordValue
		if let jumpHostServerId = input.jumpHostServerId {
			rec[Field.jumpHostServerId] = jumpHostServerId as CKRecordValue
		}
		rec[Field.forwards] = jsonEncoded(input.forwards)
		if let icon = input.icon {
			rec[Field.icon] = icon as CKRecordValue
		}
		rec[Field.organization] = jsonEncoded(input.organization)
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
		if let jumpHostServerId = host.jumpHostServerId {
			existing[Field.jumpHostServerId] = jumpHostServerId as CKRecordValue
		} else {
			existing[Field.jumpHostServerId] = nil
		}
		existing[Field.forwards] = jsonEncoded(host.forwards)
		if let icon = host.icon {
			existing[Field.icon] = icon as CKRecordValue
		} else {
			existing[Field.icon] = nil
		}
		existing[Field.organization] = jsonEncoded(host.organization)
		// `metadataUpdatedAt` was already advanced above to host.updatedAt;
		// callers (HostSyncStore) MUST bump host.updatedAt on any forwards
		// mutation, otherwise this push will not be considered newer by
		// other devices' LWW.
	}

	/// Applies a complete metadata snapshot received by the sync client.
	/// Credential fields remain untouched.
	public static func applyMetadata(
		into existing: CKRecord,
		from input: RemoteHostUpdateInput
	) {
		if let value = input.name { existing[Field.name] = value as CKRecordValue }
		if let value = input.hostname { existing[Field.hostname] = value as CKRecordValue }
		if let value = input.port { existing[Field.port] = value as CKRecordValue }
		if let value = input.username { existing[Field.username] = value as CKRecordValue }
		if let value = input.authType { existing[Field.authType] = value as CKRecordValue }
		if let value = input.metadataUpdatedAt {
			existing[Field.metadataUpdatedAt] = value as CKRecordValue
		}
		existing[Field.jumpHostServerId] = input.jumpHostServerId as CKRecordValue?
		if let value = input.forwards {
			existing[Field.forwards] = jsonEncoded(value)
		}
		existing[Field.icon] = input.icon as CKRecordValue?
		if let value = input.organization {
			existing[Field.organization] = jsonEncoded(value)
		}
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

		let forwardsJSON = (rec[Field.forwards] as? String) ?? "[]"
		let decoded: [PortForward] = {
			guard let data = forwardsJSON.data(using: .utf8) else { return [] }
			do {
				return try JSONDecoder().decode([PortForward].self, from: data)
			} catch {
				NSLog("[CKRecordHostMapping] forwards JSON decode failed for record \(rec.recordID.recordName): \(error)")
				return []
			}
		}()
		let organization: HostOrganization = {
			guard let json = rec[Field.organization] as? String,
			      let data = json.data(using: .utf8),
			      let value = try? JSONDecoder().decode(
					HostOrganization.self, from: data
			      ) else {
				return .empty
			}
			return value
		}()

		let host = RemoteHost(
			id: rec.recordID.recordName,
			name: name,
			hostname: hostname,
			port: port,
			username: username,
			authType: authType,
			createdAt: rec.creationDate ?? .distantPast,
			updatedAt: updatedAt,
			jumpHostServerId: rec[Field.jumpHostServerId] as? String,
			forwards: decoded,
			icon: rec[Field.icon] as? String,
			organization: organization
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

private func jsonEncoded(_ forwards: [PortForward]) -> CKRecordValue {
	jsonEncoded(forwards, fallback: "[]")
}

private func jsonEncoded(_ organization: HostOrganization) -> CKRecordValue {
	jsonEncoded(organization, fallback: "{}")
}

private func jsonEncoded<T: Encodable>(
	_ value: T,
	fallback: String
) -> CKRecordValue {
	guard let data = try? JSONEncoder().encode(value),
	      let string = String(data: data, encoding: .utf8) else {
		return fallback as CKRecordValue
	}
	return string as CKRecordValue
}
