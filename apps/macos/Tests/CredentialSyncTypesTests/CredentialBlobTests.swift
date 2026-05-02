import XCTest
import CredentialSyncTypes

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
}
