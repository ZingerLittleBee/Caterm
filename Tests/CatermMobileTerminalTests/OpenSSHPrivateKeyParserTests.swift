import Foundation
@testable import CatermMobileTerminal
import XCTest

final class OpenSSHPrivateKeyParserTests: XCTestCase {
	func testParsesUnencryptedEd25519PrivateKey() throws {
		XCTAssertNoThrow(try OpenSSHPrivateKeyParser.parse(Self.privateKey, passphrase: nil))
	}

	func testRejectsPassphraseProtectedPlan() {
		XCTAssertThrowsError(
			try OpenSSHPrivateKeyParser.parse(Self.privateKey, passphrase: "secret")
		) { error in
			XCTAssertEqual(error as? MobileSSHPrivateKeyError, .encryptedKeyUnsupported)
		}
	}

	func testRejectsMalformedPayload() {
		XCTAssertThrowsError(
			try OpenSSHPrivateKeyParser.parse(Data("not a key".utf8), passphrase: nil)
		) { error in
			XCTAssertEqual(error as? MobileSSHPrivateKeyError, .invalidEncoding)
		}
	}

	static let privateKey = Data(
		"""
		-----BEGIN OPENSSH PRIVATE KEY-----
		b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
		QyNTUxOQAAACBldVAoGduTlstcyABUuMX8cVKIssxLj8Y3tJ7KJdeTIAAAAJA9xWvoPcVr
		6AAAAAtzc2gtZWQyNTUxOQAAACBldVAoGduTlstcyABUuMX8cVKIssxLj8Y3tJ7KJdeTIA
		AAAEB65aRHWapKif4gyhMY/64dGZjpz9jsE4Sh8Ro++Y3SR2V1UCgZ25OWy1zIAFS4xfxx
		UoiyzEuPxje0nsol15MgAAAAC2NhdGVybS10ZXN0AQI=
		-----END OPENSSH PRIVATE KEY-----
		""".utf8
	)
}
