import XCTest
import SessionStore

final class HostSecretsTests: XCTestCase {
    func test_hostSecrets_anyPresent() {
        XCTAssertFalse(HostSecrets(password: nil, passphrase: nil, privateKeyBytes: nil).anyPresent)
        XCTAssertTrue(HostSecrets(password: Data("p".utf8), passphrase: nil, privateKeyBytes: nil).anyPresent)
        XCTAssertTrue(HostSecrets(password: nil, passphrase: nil, privateKeyBytes: Data("k".utf8)).anyPresent)
    }
}
