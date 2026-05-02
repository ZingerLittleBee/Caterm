import XCTest
@testable import ManagedKeyStore

final class ManagedKeyStoreTests: XCTestCase {
    private var tmpRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mks-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try await super.tearDown()
    }

    func test_writeRead_roundTrip() async throws {
        let store = ManagedKeyStore(rootURL: tmpRoot)
        let id = UUID()
        let bytes = Data((0..<400).map { UInt8($0 % 256) })
        let url = try await store.write(hostId: id, bytes: bytes)
        let readBack = try await store.read(hostId: id)
        XCTAssertEqual(readBack, bytes)
        let pathResult = await store.path(hostId: id)
        XCTAssertEqual(url.path, pathResult.path)
    }

    func test_write_isAtomicReplaceOfExistingTarget() async throws {
        let store = ManagedKeyStore(rootURL: tmpRoot)
        let id = UUID()
        _ = try await store.write(hostId: id, bytes: Data("v1".utf8))
        _ = try await store.write(hostId: id, bytes: Data("v2".utf8))
        let readBack = try await store.read(hostId: id)
        XCTAssertEqual(readBack, Data("v2".utf8))
    }

    func test_write_createsRootWith0700() async throws {
        let store = ManagedKeyStore(rootURL: tmpRoot)
        _ = try await store.write(hostId: UUID(), bytes: Data("x".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: tmpRoot.path)
        let perm = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perm?.intValue, 0o700)
    }

    func test_write_filePermsAre0600() async throws {
        let store = ManagedKeyStore(rootURL: tmpRoot)
        let url = try await store.write(hostId: UUID(), bytes: Data("x".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perm = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perm?.intValue, 0o600)
    }

    func test_write_rejectsOversize() async throws {
        let store = ManagedKeyStore(rootURL: tmpRoot)
        let oversize = Data(count: 1_000_001)
        do {
            _ = try await store.write(hostId: UUID(), bytes: oversize)
            XCTFail("expected throw")
        } catch ManagedKeyStore.Error.tooLarge { /* ok */ }
    }

    func test_delete_idempotent() async throws {
        let store = ManagedKeyStore(rootURL: tmpRoot)
        let id = UUID()
        await store.delete(hostId: id)  // not yet written; must not throw
        _ = try await store.write(hostId: id, bytes: Data("x".utf8))
        await store.delete(hostId: id)
        let read = try await store.read(hostId: id)
        XCTAssertNil(read)
    }

    func test_write_rejectsSymlinkAtTarget() async throws {
        let store = ManagedKeyStore(rootURL: tmpRoot)
        let id = UUID()
        // First, ensure the directory exists by writing once.
        _ = try await store.write(hostId: UUID(), bytes: Data("seed".utf8))
        // Replace the would-be target path with a symlink to /tmp/some-other.
        let target = await store.path(hostId: id)
        let elsewhere = tmpRoot.appendingPathComponent("elsewhere")
        try Data("decoy".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: elsewhere)
        do {
            _ = try await store.write(hostId: id, bytes: Data("evil".utf8))
            XCTFail("expected throw")
        } catch ManagedKeyStore.Error.unsafePath { /* ok */ }
    }
}
