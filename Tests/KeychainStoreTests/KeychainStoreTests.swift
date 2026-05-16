import XCTest
@testable import KeychainStore

final class KeychainStoreTests: XCTestCase {
    let testService = "com.caterm.host.test"
    let testAccount = "test-host-id.password"
    var store: KeychainStore!

    override func setUp() async throws {
        store = KeychainStore(
            service: testService,
            accessGroup: nil  // nil → login keychain (no codesign required)
        )
        try? store.delete(account: testAccount)
    }

    override func tearDown() async throws {
        try? store.delete(account: testAccount)
    }

    func testWriteReadRoundtrip() throws {
        try store.set(account: testAccount, secret: "p@ssw0rd!")
        let read = try store.get(account: testAccount)
        XCTAssertEqual(read, "p@ssw0rd!")
    }

    func testReadMissingThrowsNotFound() {
        XCTAssertThrowsError(try store.get(account: "no-such-account")) { error in
            guard case KeychainError.notFound = error else {
                XCTFail("Expected .notFound, got \(error)"); return
            }
        }
    }

    func testWriteOverwritesExisting() throws {
        try store.set(account: testAccount, secret: "first")
        try store.set(account: testAccount, secret: "second")
        let read = try store.get(account: testAccount)
        XCTAssertEqual(read, "second")
    }

    func testDelete() throws {
        try store.set(account: testAccount, secret: "x")
        try store.delete(account: testAccount)
        XCTAssertThrowsError(try store.get(account: testAccount))
    }

    func testDeleteByHostIdPattern() throws {
        let hostId = UUID().uuidString
        try store.set(account: "\(hostId).password", secret: "p1")
        try store.set(account: "\(hostId).keyPassphrase", secret: "p2")
        try store.deleteAll(prefix: "\(hostId).")
        XCTAssertThrowsError(try store.get(account: "\(hostId).password"))
        XCTAssertThrowsError(try store.get(account: "\(hostId).keyPassphrase"))
    }

    func testUnicodeSecret() throws {
        try store.set(account: testAccount, secret: "密码 café 😀")
        let read = try store.get(account: testAccount)
        XCTAssertEqual(read, "密码 café 😀")
    }
}
