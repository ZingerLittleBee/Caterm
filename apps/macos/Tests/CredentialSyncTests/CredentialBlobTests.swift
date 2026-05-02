import XCTest
import SessionStore
@testable import CredentialSync

final class CredentialBlobTests: XCTestCase {
	func test_state_rawValuesMatchSpec() {
		XCTAssertEqual(CredentialBlobState.none.rawValue, "none")
		XCTAssertEqual(CredentialBlobState.payload.rawValue, "payload")
		XCTAssertEqual(CredentialBlobState.tombstone.rawValue, "tombstone")
	}

	func test_blob_default_isNoneState() {
		let blob = CredentialBlob(state: .none, revision: 0, keyID: nil)
		XCTAssertNil(blob.passwordCiphertext)
		XCTAssertNil(blob.passphraseCiphertext)
		XCTAssertNil(blob.privateKeyCiphertext)
		XCTAssertEqual(blob.cryptoVersion, 1)
	}

	func test_hostSecrets_anyPresent() {
		XCTAssertFalse(HostSecrets(password: nil, passphrase: nil, privateKeyBytes: nil).anyPresent)
		XCTAssertTrue(HostSecrets(password: Data("p".utf8), passphrase: nil, privateKeyBytes: nil).anyPresent)
		XCTAssertTrue(HostSecrets(password: nil, passphrase: nil, privateKeyBytes: Data("k".utf8)).anyPresent)
	}
}
