import CloudKit
import CredentialIdentityStore
import Foundation

public enum CKRecordCredentialIdentityMapping {
	public static let recordType: CKRecord.RecordType = "CredentialIdentity"

	enum Field {
		static let metadata = "metadata"
		static let keyID = "credentialKeyID"
		static let cryptoVersion = "credentialCryptoVersion"
		static let passwordCiphertext = "passwordCiphertext"
		static let passphraseCiphertext = "passphraseCiphertext"
		static let privateKeyCiphertext = "privateKeyCiphertext"
	}

	public enum MappingError: Error, Equatable {
		case invalidMetadata
	}

	public static func makeRecord(
		record: CredentialIdentitySyncRecord,
		zoneID: CKRecordZone.ID
	) throws -> CKRecord {
		let recordName = record.identity.id.uuidString
		let cloudRecord = CKRecord(
			recordType: recordType,
			recordID: CKRecord.ID(
				recordName: recordName,
				zoneID: zoneID
			)
		)
		try apply(record, to: cloudRecord)
		return cloudRecord
	}

	public static func apply(
		_ record: CredentialIdentitySyncRecord,
		to cloudRecord: CKRecord
	) throws {
		let data = try JSONEncoder().encode(record.identity)
		guard let metadata = String(data: data, encoding: .utf8) else {
			throw MappingError.invalidMetadata
		}
		cloudRecord[Field.metadata] = metadata as CKRecordValue
		cloudRecord[Field.keyID] = record.keyID as CKRecordValue?
		cloudRecord[Field.cryptoVersion] =
			record.cryptoVersion as CKRecordValue
		cloudRecord[Field.passwordCiphertext] =
			record.passwordCiphertext as CKRecordValue?
		cloudRecord[Field.passphraseCiphertext] =
			record.passphraseCiphertext as CKRecordValue?
		cloudRecord[Field.privateKeyCiphertext] =
			record.privateKeyCiphertext as CKRecordValue?
	}

	public static func decode(
		_ cloudRecord: CKRecord
	) throws -> CredentialIdentitySyncRecord {
		guard let metadata = cloudRecord[Field.metadata] as? String,
		      let data = metadata.data(using: .utf8) else {
			throw MappingError.invalidMetadata
		}
		var identity = try JSONDecoder().decode(
			CredentialIdentity.self,
			from: data
		).validated()
		guard identity.id.uuidString == cloudRecord.recordID.recordName else {
			throw MappingError.invalidMetadata
		}
		identity.serverID = cloudRecord.recordID.recordName
		return CredentialIdentitySyncRecord(
			identity: identity,
			keyID: cloudRecord[Field.keyID] as? String,
			cryptoVersion: (
				cloudRecord[Field.cryptoVersion] as? Int64
			) ?? 1,
			passwordCiphertext:
				cloudRecord[Field.passwordCiphertext] as? Data,
			passphraseCiphertext:
				cloudRecord[Field.passphraseCiphertext] as? Data,
			privateKeyCiphertext:
				cloudRecord[Field.privateKeyCiphertext] as? Data
		)
	}
}
