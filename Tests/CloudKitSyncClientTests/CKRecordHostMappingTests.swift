import CloudKit
import CredentialSyncTypes
import ServerSyncClient
import SSHCommandBuilder
import XCTest
@testable import CloudKitSyncClient

final class CKRecordHostMappingTests: XCTestCase {
	private let zoneID = CKRecordZone.ID(zoneName: "Caterm")

	func testEncodeCreateInputProducesRecordWithFields() {
		let input = RemoteHostCreateInput(
			name: "alpha", hostname: "x.example.com", port: 2222, username: "u"
		)
		let recordName = "abc-123"
		let rec = CKRecordHostMapping.makeRecord(
			recordName: recordName, zoneID: zoneID, input: input
		)
		XCTAssertEqual(rec.recordType, "Host")
		XCTAssertEqual(rec.recordID.recordName, recordName)
		XCTAssertEqual(rec.recordID.zoneID, zoneID)
		XCTAssertEqual(rec["name"] as? String, "alpha")
		XCTAssertEqual(rec["hostname"] as? String, "x.example.com")
		XCTAssertEqual(rec["port"] as? Int, 2222)
		XCTAssertEqual(rec["username"] as? String, "u")
		XCTAssertEqual(rec["authType"] as? String, "key")
	}

	func testDecodeRecordWithAllFieldsProducesRemoteHost() throws {
		let recID = CKRecord.ID(recordName: "rec-1", zoneID: zoneID)
		let rec = CKRecord(recordType: "Host", recordID: recID)
		rec["name"] = "alpha" as CKRecordValue
		rec["hostname"] = "x" as CKRecordValue
		rec["port"] = 22 as CKRecordValue
		rec["username"] = "u" as CKRecordValue
		rec["authType"] = "key" as CKRecordValue
		// creationDate/modificationDate are normally set by the server.
		// Local CKRecord starts with nil — we reflect that via mapping
		// fallback to Date.distantPast so reconciler treats unsynced as
		// older than any real remote record.

		let host = try CKRecordHostMapping.decode(rec).host
		XCTAssertEqual(host.id, "rec-1")
		XCTAssertEqual(host.name, "alpha")
		XCTAssertEqual(host.hostname, "x")
		XCTAssertEqual(host.port, 22)
		XCTAssertEqual(host.username, "u")
		XCTAssertEqual(host.authType, "key")
		XCTAssertEqual(host.createdAt, .distantPast)
		XCTAssertEqual(host.updatedAt, .distantPast)
	}

	func testDecodeMissingHostnameThrows() {
		let recID = CKRecord.ID(recordName: "rec-bad", zoneID: zoneID)
		let rec = CKRecord(recordType: "Host", recordID: recID)
		rec["name"] = "x" as CKRecordValue
		// hostname intentionally omitted
		rec["port"] = 22 as CKRecordValue
		rec["username"] = "u" as CKRecordValue
		XCTAssertThrowsError(try CKRecordHostMapping.decode(rec)) { error in
			XCTAssertEqual(error as? CKRecordHostMapping.DecodeError,
						   .missingField("hostname"))
		}
	}

	// MARK: - New tests

	func testMakeRecordSeedsCredentialFieldsToNone() {
		let input = RemoteHostCreateInput(
			name: "beta", hostname: "b.example.com", port: 22, username: "u"
		)
		let rec = CKRecordHostMapping.makeRecord(
			recordName: "seed-test", zoneID: zoneID, input: input
		)
		XCTAssertEqual(rec["credentialBlobState"] as? String, "none")
		XCTAssertEqual(rec["credentialBlobRevision"] as? Int64, 0)
		XCTAssertEqual(rec["credentialCryptoVersion"] as? Int64, 1)
	}

	func testMakeRecordSetsMetadataUpdatedAt() {
		let before = Date()
		let input = RemoteHostCreateInput(
			name: "gamma", hostname: "g.example.com", port: 22, username: "u"
		)
		let rec = CKRecordHostMapping.makeRecord(
			recordName: "ts-test", zoneID: zoneID, input: input
		)
		let after = Date()
		let ts = rec["metadataUpdatedAt"] as? Date
		XCTAssertNotNil(ts)
		XCTAssertGreaterThanOrEqual(ts!, before)
		XCTAssertLessThanOrEqual(ts!, after)
	}

	func testApplyMetadataOnlyTouchesMetadataFields() {
		// Build a record with existing credential blob fields.
		let recID = CKRecord.ID(recordName: "apply-meta", zoneID: zoneID)
		let rec = CKRecord(recordType: "Host", recordID: recID)
		rec["credentialBlobState"] = "payload" as CKRecordValue
		rec["credentialBlobRevision"] = Int64(7) as CKRecordValue
		rec["credentialCryptoVersion"] = Int64(1) as CKRecordValue
		rec["credentialKeyID"] = "k-1" as CKRecordValue

		let updatedAt = Date(timeIntervalSince1970: 1_000_000)
		let host = SSHHost(
			id: UUID(), serverId: "apply-meta",
			name: "new-name", hostname: "new.host", port: 2022,
			username: "new-user", credential: .password,
			createdAt: Date(), updatedAt: updatedAt
		)
		CKRecordHostMapping.applyMetadata(into: rec, from: host)

		// Metadata was updated.
		XCTAssertEqual(rec["name"] as? String, "new-name")
		XCTAssertEqual(rec["hostname"] as? String, "new.host")
		XCTAssertEqual(rec["port"] as? Int, 2022)
		XCTAssertEqual(rec["username"] as? String, "new-user")
		XCTAssertEqual(rec["metadataUpdatedAt"] as? Date, updatedAt)

		// Credential fields untouched.
		XCTAssertEqual(rec["credentialBlobState"] as? String, "payload")
		XCTAssertEqual(rec["credentialBlobRevision"] as? Int64, 7)
		XCTAssertEqual(rec["credentialKeyID"] as? String, "k-1")
	}

	func testApplyCredentialBlobWritesAllFields() {
		let recID = CKRecord.ID(recordName: "apply-cred", zoneID: zoneID)
		let rec = CKRecord(recordType: "Host", recordID: recID)
		let pw = Data("ciphertext".utf8)
		let blob = CredentialBlob(
			state: .payload,
			revision: 3,
			keyID: "key-xyz",
			cryptoVersion: 1,
			passwordCiphertext: pw,
			passphraseCiphertext: nil,
			privateKeyCiphertext: nil
		)
		CKRecordHostMapping.applyCredentialBlob(into: rec, blob: blob)

		XCTAssertEqual(rec["credentialBlobState"] as? String, "payload")
		XCTAssertEqual(rec["credentialBlobRevision"] as? Int64, 3)
		XCTAssertEqual(rec["credentialCryptoVersion"] as? Int64, 1)
		XCTAssertEqual(rec["credentialKeyID"] as? String, "key-xyz")
		XCTAssertEqual(rec["passwordCiphertext"] as? Data, pw)
		XCTAssertNil(rec["passphraseCiphertext"])
		XCTAssertNil(rec["privateKeyCiphertext"])
	}

	func testApplyCredentialBlobClearsNilFields() {
		// Pre-populate optional fields, then overwrite with a blob that has
		// nil values — they must be cleared on the record.
		let recID = CKRecord.ID(recordName: "clear-cred", zoneID: zoneID)
		let rec = CKRecord(recordType: "Host", recordID: recID)
		rec["credentialKeyID"] = "old-key" as CKRecordValue
		rec["passwordCiphertext"] = Data("old".utf8) as CKRecordValue
		rec["passphraseCiphertext"] = Data("old-pp".utf8) as CKRecordValue
		rec["privateKeyCiphertext"] = Data("old-pk".utf8) as CKRecordValue

		let blob = CredentialBlob(
			state: .tombstone,
			revision: 9,
			keyID: nil,
			cryptoVersion: 1,
			passwordCiphertext: nil,
			passphraseCiphertext: nil,
			privateKeyCiphertext: nil
		)
		CKRecordHostMapping.applyCredentialBlob(into: rec, blob: blob)

		XCTAssertNil(rec["credentialKeyID"])
		XCTAssertNil(rec["passwordCiphertext"])
		XCTAssertNil(rec["passphraseCiphertext"])
		XCTAssertNil(rec["privateKeyCiphertext"])
	}

	func testDecodeReturnsNilBlobWhenStateIsNone() throws {
		let recID = CKRecord.ID(recordName: "no-blob", zoneID: zoneID)
		let rec = CKRecord(recordType: "Host", recordID: recID)
		rec["name"] = "h" as CKRecordValue
		rec["hostname"] = "h.example.com" as CKRecordValue
		rec["port"] = 22 as CKRecordValue
		rec["username"] = "u" as CKRecordValue
		rec["credentialBlobState"] = "none" as CKRecordValue

		let result = try CKRecordHostMapping.decode(rec)
		XCTAssertNil(result.blob)
	}

	func testDecodeReturnsPopulatedBlobWhenStateIsPayload() throws {
		let recID = CKRecord.ID(recordName: "has-blob", zoneID: zoneID)
		let rec = CKRecord(recordType: "Host", recordID: recID)
		rec["name"] = "h" as CKRecordValue
		rec["hostname"] = "h.example.com" as CKRecordValue
		rec["port"] = 22 as CKRecordValue
		rec["username"] = "u" as CKRecordValue
		rec["credentialBlobState"] = "payload" as CKRecordValue
		rec["credentialBlobRevision"] = Int64(5) as CKRecordValue
		rec["credentialKeyID"] = "k-99" as CKRecordValue
		rec["credentialCryptoVersion"] = Int64(1) as CKRecordValue
		let pw = Data("pw-cipher".utf8)
		rec["passwordCiphertext"] = pw as CKRecordValue

		let result = try CKRecordHostMapping.decode(rec)
		let blob = try XCTUnwrap(result.blob)
		XCTAssertEqual(blob.state, .payload)
		XCTAssertEqual(blob.revision, 5)
		XCTAssertEqual(blob.keyID, "k-99")
		XCTAssertEqual(blob.cryptoVersion, 1)
		XCTAssertEqual(blob.passwordCiphertext, pw)
		XCTAssertNil(blob.passphraseCiphertext)
		XCTAssertNil(blob.privateKeyCiphertext)
	}

	func testDecodeUsesMetadataUpdatedAtForUpdatedAt() throws {
		let recID = CKRecord.ID(recordName: "ts-decode", zoneID: zoneID)
		let rec = CKRecord(recordType: "Host", recordID: recID)
		rec["name"] = "h" as CKRecordValue
		rec["hostname"] = "h.example.com" as CKRecordValue
		rec["port"] = 22 as CKRecordValue
		rec["username"] = "u" as CKRecordValue
		let ts = Date(timeIntervalSince1970: 1_234_567)
		rec["metadataUpdatedAt"] = ts as CKRecordValue

		let result = try CKRecordHostMapping.decode(rec)
		XCTAssertEqual(result.host.updatedAt, ts)
	}
}
