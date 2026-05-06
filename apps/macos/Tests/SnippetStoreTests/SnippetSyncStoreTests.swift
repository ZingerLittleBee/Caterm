import XCTest
import SnippetSyncClient
@testable import SnippetStore

@MainActor
final class SnippetSyncStoreTests: XCTestCase {
	private func tempDir() -> URL {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("snippet-sync-store-tests-\(UUID().uuidString)")
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	func test_syncPass_drainsOutboxBeforeFetchAndPush() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		try store.upsert(Snippet(id: id, name: "a", content: "b",
		                         createdAt: .now, updatedAt: .now))
		try store.delete(id: id)

		let client = FakeSnippetSyncClient()
		let sync = SnippetSyncStore(store: store, client: client)

		await sync.runSyncPass(mode: .incremental)
		XCTAssertEqual(client.deleted, [id])
		XCTAssertFalse(store.pendingDeletedSnippetIDs.contains(id))
	}

	func test_syncPass_appliesRemoteAfterFetch_beforePush() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		// Local has revision 1. Remote arrives with revision 5.
		try store.upsert(Snippet(id: id, name: "local", content: "x",
		                         createdAt: .distantPast,
		                         updatedAt: Date(timeIntervalSince1970: 1),
		                         revision: 1))

		let remote = Snippet(id: id, name: "remote", content: "y",
		                     createdAt: .distantPast,
		                     updatedAt: Date(timeIntervalSince1970: 100),
		                     revision: 5)
		let client = FakeSnippetSyncClient()
		client.queuedFetch = SnippetChangeBatch(
			changedSnippets: [remote], deletedSnippetIDs: [],
			checkpoint: nil, tokenExpired: false, mode: .incremental
		)
		let sync = SnippetSyncStore(store: store, client: client)

		await sync.runSyncPass(mode: .incremental)
		XCTAssertEqual(store.snippets.first?.name, "remote")
		XCTAssertTrue(client.pushed.isEmpty,
		              "Remote revision 5 > local 1; local must NOT be pushed")
	}

	func test_syncPass_remoteTombstoneBeatsDirtyLocalEdit() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		try store.upsert(Snippet(id: id, name: "local", content: "x",
		                         createdAt: .now, updatedAt: .now))

		let client = FakeSnippetSyncClient()
		client.queuedFetch = SnippetChangeBatch(
			changedSnippets: [], deletedSnippetIDs: [id],
			checkpoint: nil, tokenExpired: false, mode: .incremental
		)
		let sync = SnippetSyncStore(store: store, client: client)
		sync.markDirty(id)
		await sync.runSyncPass(mode: .incremental)

		XCTAssertTrue(store.snippets.isEmpty)
		XCTAssertTrue(client.pushed.isEmpty)
	}

	func test_runSyncPass_commitsCheckpointAfterApply() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let cp = StubCheckpoint()
		let client = FakeSnippetSyncClient()
		client.queuedFetch = SnippetChangeBatch(
			changedSnippets: [], deletedSnippetIDs: [],
			checkpoint: cp, tokenExpired: false, mode: .incremental
		)
		let sync = SnippetSyncStore(store: store, client: client)
		await sync.runSyncPass(mode: .incremental)
		XCTAssertEqual(client.committedCheckpoints.count, 1)
	}

	func test_concurrentTriggers_serializeIntoOnePassAndOneFollowup() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let client = FakeSnippetSyncClient()
		client.fetchDelay = .milliseconds(50)
		let sync = SnippetSyncStore(store: store, client: client)
		// Fire 3 schedule calls back-to-back; expect ≤ 2 actual passes.
		sync.scheduleSyncPass(mode: .incremental)
		sync.scheduleSyncPass(mode: .incremental)
		sync.scheduleSyncPass(mode: .incremental)
		try await Task.sleep(for: .milliseconds(200))
		XCTAssertLessThanOrEqual(client.fetchCallCount, 2)
		XCTAssertGreaterThanOrEqual(client.fetchCallCount, 1)
	}
}

private struct StubCheckpoint: SnippetSyncCheckpoint {
	let id = UUID()
}

@MainActor
private final class FakeSnippetSyncClient: IncrementalSnippetSyncClient {
	var queuedFetch: SnippetChangeBatch?
	var pushed: [Snippet] = []
	var deleted: [UUID] = []
	var committedCheckpoints: [any SnippetSyncCheckpoint] = []
	var fetchCallCount = 0
	var fetchDelay: Duration = .zero
	var subscriptions: Set<String> = []
	var hasTokens = false

	func preferredSnippetSyncMode() async -> SnippetSyncMode { .incremental }

	func fetchSnippetChanges() async throws -> SnippetChangeBatch {
		fetchCallCount += 1
		if fetchDelay > .zero { try? await Task.sleep(for: fetchDelay) }
		return queuedFetch ?? SnippetChangeBatch(
			changedSnippets: [], deletedSnippetIDs: [],
			checkpoint: nil, tokenExpired: false, mode: .incremental
		)
	}

	func fetchSnippetSnapshotAndCheckpoint() async throws -> SnippetChangeBatch {
		fetchCallCount += 1
		return queuedFetch ?? SnippetChangeBatch(
			changedSnippets: [], deletedSnippetIDs: [],
			checkpoint: nil, tokenExpired: false, mode: .forceFull
		)
	}

	func commitSnippetCheckpoint(_ checkpoint: any SnippetSyncCheckpoint) async throws {
		committedCheckpoints.append(checkpoint)
	}

	func resetSnippetSyncState() async { hasTokens = false }
	func ensureSnippetSubscription() async throws {
		subscriptions.insert("snippet")
	}
	func deleteSnippetSubscription() async throws {
		subscriptions.remove("snippet")
	}
	func pushSnippet(_ s: Snippet) async throws -> Snippet {
		pushed.append(s)
		var copy = s
		copy.metadataUpdatedAt = Date()
		return copy
	}
	func deleteSnippet(id: UUID) async throws { deleted.append(id) }
	func hasAnySnippetSyncTokens() async -> Bool { hasTokens }
}
