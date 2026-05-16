import CryptoKit
import CredentialSyncStore
import XCTest

final class KeychainSyncMasterKeyStoreTests: XCTestCase {
    /// We use a unique service per test so concurrent runs don't collide.
    private func makeStore() -> KeychainSyncMasterKeyStore {
        KeychainSyncMasterKeyStore(
            service: "com.caterm.test.cloudkit-sync.masterKey.\(UUID().uuidString)",
            synchronizable: false
        )
    }

    func test_loadAny_emptyStoreReturnsNil() async {
        let store = makeStore()
        let result = await store.loadAny()
        XCTAssertNil(result)
    }

    func test_generate_thenLoadByID_roundTrips() async throws {
        let store = makeStore()
        let (keyID, key) = try await store.generate()
        defer { Task { await store.remove(keyID: keyID) } }
        let loaded = await store.load(keyID: keyID)
        XCTAssertEqual(loaded?.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
    }

    func test_loadAny_returnsAnyExistingKey() async throws {
        let store = makeStore()
        let (id, _) = try await store.generate()
        defer { Task { await store.remove(keyID: id) } }
        let any = await store.loadAny()
        XCTAssertNotNil(any)
        XCTAssertEqual(any?.keyID, id)
    }

    func test_remove_idempotent() async throws {
        let store = makeStore()
        let (id, _) = try await store.generate()
        await store.remove(keyID: id)
        await store.remove(keyID: id)  // second call: must not throw / crash
        let afterRemove = await store.load(keyID: id)
        XCTAssertNil(afterRemove)
    }
}
