import XCTest
@testable import SessionStore

@MainActor
final class RemoteBookmarkStoreTests: XCTestCase {
    private var tempDir: URL!
    private let hostA = UUID()
    private let hostB = UUID()

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteBookmarkStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func makeStore() -> RemoteBookmarkStore {
        RemoteBookmarkStore(directory: tempDir)
    }

    private func makeBookmark(label: String, path: String) -> RemoteBookmark {
        RemoteBookmark(id: UUID(), label: label, path: path,
                       createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Empty state

    func test_emptyState_whenFileMissing() {
        let store = makeStore()
        XCTAssertEqual(store.bookmarks(for: hostA), [])
        XCTAssertFalse(store.isQuarantined(for: hostA))
    }

    // MARK: - Add / list / verbatim round-trip

    func test_add_thenList_storesPathVerbatim() {
        let store = makeStore()
        let bm = makeBookmark(label: "Home", path: "~")
        XCTAssertTrue(store.add(bm, for: hostA))
        XCTAssertEqual(store.bookmarks(for: hostA), [bm])
        XCTAssertEqual(store.bookmarks(for: hostA).first?.path, "~",
                       "stored path must remain literal '~' (no local tilde expansion)")
    }

    func test_add_thenReload_persistsAcrossInstances() {
        let storeA = makeStore()
        let bm = makeBookmark(label: "Logs", path: "/var/log")
        _ = storeA.add(bm, for: hostA)

        let storeB = makeStore()
        XCTAssertEqual(storeB.bookmarks(for: hostA), [bm])
    }

    // MARK: - Delete

    func test_remove_dropsMatchingEntry() {
        let store = makeStore()
        let bm1 = makeBookmark(label: "A", path: "/a")
        let bm2 = makeBookmark(label: "B", path: "/b")
        _ = store.add(bm1, for: hostA)
        _ = store.add(bm2, for: hostA)

        store.remove(id: bm1.id, for: hostA)
        XCTAssertEqual(store.bookmarks(for: hostA), [bm2])
    }

    // MARK: - Reorder

    func test_move_preservesOrderAcrossReload() {
        let store = makeStore()
        let bm1 = makeBookmark(label: "A", path: "/a")
        let bm2 = makeBookmark(label: "B", path: "/b")
        let bm3 = makeBookmark(label: "C", path: "/c")
        _ = store.add(bm1, for: hostA)
        _ = store.add(bm2, for: hostA)
        _ = store.add(bm3, for: hostA)

        store.move(from: 0, to: 2, for: hostA)
        // Swift Array.move(fromOffsets:toOffset:) semantics: moving index 0
        // to offset 2 places it before what was at index 2, leaving [B, A, C].
        XCTAssertEqual(store.bookmarks(for: hostA).map(\.label), ["B", "A", "C"])

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.bookmarks(for: hostA).map(\.label), ["B", "A", "C"])
    }

    // MARK: - Dedup keeps ~ literal

    func test_dedup_addingSameTildeTwice_isNoOp_preservesLiteral() {
        let store = makeStore()
        let first = makeBookmark(label: "Home", path: "~")
        XCTAssertTrue(store.add(first, for: hostA))

        let second = makeBookmark(label: "Home Again", path: "~")
        XCTAssertFalse(store.add(second, for: hostA))

        XCTAssertEqual(store.bookmarks(for: hostA).count, 1)
        XCTAssertEqual(store.bookmarks(for: hostA).first?.path, "~",
                       "dedup must NOT replace stored '~' with /Users/...")
        XCTAssertEqual(store.bookmarks(for: hostA).first?.label, "Home",
                       "dedup is no-op — first wins, second never written")
    }

    // MARK: - Dedup is lexical-only

    func test_dedup_collapsesDoubleSlashOnTilde() {
        let store = makeStore()
        _ = store.add(makeBookmark(label: "X", path: "~/projects"), for: hostA)
        XCTAssertFalse(store.add(makeBookmark(label: "Y", path: "~//projects"),
                                 for: hostA))
    }

    func test_dedup_collapsesTrailingSlashOnAbsolute() {
        let store = makeStore()
        _ = store.add(makeBookmark(label: "X", path: "/var/log"), for: hostA)
        XCTAssertFalse(store.add(makeBookmark(label: "Y", path: "/var/log/"),
                                 for: hostA))
    }

    func test_dedup_doesNotResolveTildeAgainstLocalUser() {
        let store = makeStore()
        _ = store.add(makeBookmark(label: "X", path: "~/projects"), for: hostA)
        // Even if /Users/zingerbee/projects is what ~/projects resolves to
        // locally, the dedup is lexical only — these are different keys.
        XCTAssertTrue(store.add(makeBookmark(label: "Y", path: "/Users/foo/projects"),
                                for: hostA),
                      "lexical dedup must not collide ~/X with /Users/foo/X")
    }

    // MARK: - Corruption recovery

    func test_corruption_recoversToEmpty_quarantinesOriginal() throws {
        let path = tempDir.appendingPathComponent("\(hostA.uuidString).json")
        try Data("{ this is not json".utf8).write(to: path)

        let store = makeStore()
        XCTAssertEqual(store.bookmarks(for: hostA), [])
        XCTAssertFalse(store.isQuarantined(for: hostA),
                       "garbage JSON is recoverable corruption (not future-version quarantine)")

        // Original file moved to .broken-<timestamp> sidecar
        let siblings = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let brokenCount = siblings.filter { $0.contains(".json.broken-") }.count
        XCTAssertEqual(brokenCount, 1, "corrupted file must be quarantined to .broken-<ts>")
    }

    // MARK: - Unknown version → read-only quarantine

    func test_unknownVersion_isReadOnlyQuarantine() throws {
        let path = tempDir.appendingPathComponent("\(hostA.uuidString).json")
        let future = #"{"version": 99, "bookmarks": []}"#
        try Data(future.utf8).write(to: path)
        let originalBytes = try Data(contentsOf: path)

        let store = makeStore()
        XCTAssertTrue(store.isQuarantined(for: hostA),
                      "newer-schema file must enter read-only quarantine")
        XCTAssertEqual(store.bookmarks(for: hostA), [],
                       "in-memory list is empty while quarantined")

        let bm = makeBookmark(label: "X", path: "/x")
        XCTAssertFalse(store.add(bm, for: hostA),
                       "add() must be no-op while quarantined")

        // File on disk MUST be unchanged — we refuse to overwrite a future-
        // schema blob with a v1-shaped one.
        let afterBytes = try Data(contentsOf: path)
        XCTAssertEqual(originalBytes, afterBytes,
                       "quarantined file must not be overwritten")
    }

    func test_unknownVersion_clearsAfterUserMovesFile() throws {
        let path = tempDir.appendingPathComponent("\(hostA.uuidString).json")
        try Data(#"{"version": 99, "bookmarks": []}"#.utf8).write(to: path)
        _ = makeStore()  // triggers quarantine

        // Simulate the user moving the future-schema file aside.
        try FileManager.default.removeItem(at: path)

        let store2 = makeStore()
        XCTAssertFalse(store2.isQuarantined(for: hostA),
                       "fresh store sees no file → no quarantine")
        let bm = makeBookmark(label: "X", path: "/x")
        XCTAssertTrue(store2.add(bm, for: hostA),
                      "add() succeeds once the future-schema file is gone")
    }

    // MARK: - Per-host isolation

    func test_perHostIsolation() {
        let store = makeStore()
        let bmA = makeBookmark(label: "A", path: "/a")
        let bmB = makeBookmark(label: "B", path: "/b")
        _ = store.add(bmA, for: hostA)
        _ = store.add(bmB, for: hostB)

        XCTAssertEqual(store.bookmarks(for: hostA), [bmA])
        XCTAssertEqual(store.bookmarks(for: hostB), [bmB])
    }

    // MARK: - normalizeRemotePath edge cases (white-box for the dedup helper)

    func test_normalizeRemotePath_collapsesRunsOfSlashes() {
        XCTAssertEqual(normalizeRemotePath("//"), "/")
        XCTAssertEqual(normalizeRemotePath("/var//log"), "/var/log")
        XCTAssertEqual(normalizeRemotePath("~///foo"), "~/foo")
    }

    func test_normalizeRemotePath_stripsTrailingSlashExceptRoot() {
        XCTAssertEqual(normalizeRemotePath("/var/log/"), "/var/log")
        XCTAssertEqual(normalizeRemotePath("/"), "/")
    }

    func test_normalizeRemotePath_preservesTildeAndRelative() {
        XCTAssertEqual(normalizeRemotePath("~"), "~")
        XCTAssertEqual(normalizeRemotePath("~/foo"), "~/foo")
        XCTAssertEqual(normalizeRemotePath("relative/path"), "relative/path")
        XCTAssertEqual(normalizeRemotePath("~user/x"), "~user/x")
    }

    func test_normalizeRemotePath_trimsWhitespace() {
        XCTAssertEqual(normalizeRemotePath("  /var/log  "), "/var/log")
    }
}
