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

    func testDeleteAllNoMatchesDoesNotThrow() throws {
        // No items under this prefix → SecItemCopyMatching returns
        // errSecItemNotFound, which is the desired end state, not a
        // partial-delete failure.
        XCTAssertNoThrow(try store.deleteAll(prefix: "absent-\(UUID().uuidString).") )
    }

    func testDeleteAllSucceedsWhenItemsAlreadyGone() throws {
        let hostId = UUID().uuidString
        try store.set(account: "\(hostId).password", secret: "p1")
        // First sweep removes it; a second sweep finds the item already
        // gone (per-item .notFound) and must still succeed rather than
        // surfacing a spurious partial-delete failure.
        try store.deleteAll(prefix: "\(hostId).")
        XCTAssertNoThrow(try store.deleteAll(prefix: "\(hostId).") )
    }

    func testUnicodeSecret() throws {
        try store.set(account: testAccount, secret: "密码 café 😀")
        let read = try store.get(account: testAccount)
        XCTAssertEqual(read, "密码 café 😀")
    }
}
