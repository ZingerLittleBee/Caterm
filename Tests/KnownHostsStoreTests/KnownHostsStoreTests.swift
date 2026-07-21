import Foundation
import XCTest
@testable import KnownHostsStore

final class KnownHostsStoreTests: XCTestCase {
	private var root: URL!
	private var catermURL: URL!
	private var userURL: URL!

	override func setUpWithError() throws {
		root = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(
			at: root,
			withIntermediateDirectories: true
		)
		catermURL = root.appendingPathComponent("caterm_known_hosts")
		userURL = root.appendingPathComponent("user_known_hosts")
	}

	override func tearDownWithError() throws {
		try FileManager.default.removeItem(at: root)
	}

	func testLoadParsesOpenSSHFieldsAndFingerprint() throws {
		try write(
			"# comment\nexample.com,[example.com]:2222 ssh-ed25519 AQIDBA== laptop key\n",
			to: catermURL
		)
		let repository = KnownHostsRepository(
			catermURL: catermURL,
			userURL: userURL
		)

		let snapshot = repository.load()

		XCTAssertTrue(snapshot.issues.isEmpty)
		let record = try XCTUnwrap(snapshot.records.first)
		XCTAssertEqual(record.source, .caterm)
		XCTAssertEqual(record.hosts, ["example.com", "[example.com]:2222"])
		XCTAssertEqual(record.keyType, "ssh-ed25519")
		XCTAssertEqual(
			record.fingerprint,
			"SHA256:n2SnR+G5fxMfq7a0Rylsm28CAeefs8U1bmx36JtqgGo"
		)
		XCTAssertEqual(record.comment, "laptop key")
		XCTAssertNil(record.marker)
		XCTAssertTrue(record.isValid)
	}

	func testLoadPreservesMarkersHashedHostsAndMalformedEntries() throws {
		try write(
			"@revoked |1|salt|hash ssh-rsa AQIDBA== compromised\nmalformed entry\n",
			to: userURL
		)
		let repository = KnownHostsRepository(
			catermURL: catermURL,
			userURL: userURL
		)

		let records = repository.load().records

		XCTAssertEqual(records.count, 2)
		XCTAssertEqual(records[0].marker, "@revoked")
		XCTAssertEqual(records[0].hosts, ["|1|salt|hash"])
		XCTAssertTrue(records[0].isHashed)
		XCTAssertTrue(records[0].isValid)
		XCTAssertFalse(records[1].isValid)
		XCTAssertEqual(records[1].rawLine, "malformed entry")
	}

	func testLoadReturnsOtherSourceWhenOneFileIsUnreadable() throws {
		try write("example.com ssh-ed25519 AQIDBA==\n", to: catermURL)
		try FileManager.default.createDirectory(
			at: userURL,
			withIntermediateDirectories: true
		)
		let repository = KnownHostsRepository(
			catermURL: catermURL,
			userURL: userURL
		)

		let snapshot = repository.load()

		XCTAssertEqual(snapshot.records.count, 1)
		XCTAssertEqual(snapshot.issues.map(\.source), [.user])
	}

	func testDeleteReloadsFileAndRemovesOnlyExactOccurrence() throws {
		let duplicate = "example.com ssh-ed25519 AQIDBA=="
		try write("# keep\n\(duplicate)\nother.example ssh-rsa AQIDBA==\n\(duplicate)\n", to: userURL)
		let repository = KnownHostsRepository(
			catermURL: catermURL,
			userURL: userURL
		)
		let record = try XCTUnwrap(repository.load().records.last)
		try write(
			"# externally added\n# keep\n\(duplicate)\nother.example ssh-rsa AQIDBA==\n\(duplicate)\n",
			to: userURL
		)

		try repository.delete(record)

		XCTAssertEqual(
			try String(contentsOf: userURL, encoding: .utf8),
			"# externally added\n# keep\n\(duplicate)\nother.example ssh-rsa AQIDBA==\n"
		)
	}

	func testDeleteRejectsAStaleRecord() throws {
		try write("example.com ssh-ed25519 AQIDBA==\n", to: catermURL)
		let repository = KnownHostsRepository(
			catermURL: catermURL,
			userURL: userURL
		)
		let record = try XCTUnwrap(repository.load().records.first)
		try write("different.example ssh-ed25519 AQIDBA==\n", to: catermURL)

		XCTAssertThrowsError(try repository.delete(record)) { error in
			XCTAssertEqual(error as? KnownHostsStoreError, .recordNoLongerExists)
		}
	}

	func testImportAddsValidUniqueEntriesAndKeepsDestinationPermissions() throws {
		let importedURL = root.appendingPathComponent("imported")
		let existing = "existing.example ssh-ed25519 AQIDBA=="
		let added = "@cert-authority *.example.com ssh-rsa AQIDBA== company ca"
		try write("\(existing)\n", to: catermURL)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o640],
			ofItemAtPath: catermURL.path
		)
		try write("# ignored\n\(existing)\n\(added)\ninvalid\n", to: importedURL)
		let repository = KnownHostsRepository(
			catermURL: catermURL,
			userURL: userURL
		)

		let count = try repository.importEntries(from: importedURL)

		XCTAssertEqual(count, 1)
		XCTAssertEqual(
			try String(contentsOf: catermURL, encoding: .utf8),
			"\(existing)\n\(added)\n"
		)
		let attributes = try FileManager.default.attributesOfItem(
			atPath: catermURL.path
		)
		XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o640)
	}

	func testImportCreatesDestinationWithOwnerOnlyPermissions() throws {
		let importedURL = root.appendingPathComponent("imported")
		try write("example.com ssh-ed25519 AQIDBA==\n", to: importedURL)
		let repository = KnownHostsRepository(
			catermURL: catermURL,
			userURL: userURL
		)

		XCTAssertEqual(try repository.importEntries(from: importedURL), 1)

		let attributes = try FileManager.default.attributesOfItem(
			atPath: catermURL.path
		)
		XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
	}

	private func write(_ contents: String, to url: URL) throws {
		try contents.write(to: url, atomically: true, encoding: .utf8)
	}
}
