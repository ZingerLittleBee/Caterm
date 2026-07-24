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

		try await sync.runSyncPass(mode: .incremental)
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

		try await sync.runSyncPass(mode: .incremental)
		XCTAssertEqual(store.snippets.first?.name, "remote")
		XCTAssertTrue(store.locallyDirtySnippetIDs.isEmpty)
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
		try await sync.runSyncPass(mode: .incremental)

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
		try await sync.runSyncPass(mode: .incremental)
		XCTAssertEqual(client.committedCheckpoints.count, 1)
	}

	func test_runSyncPass_propagatesFetchFailure() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let client = FakeSnippetSyncClient()
		client.fetchError = TestSnippetSyncError.fetchFailed
		let sync = SnippetSyncStore(store: store, client: client)

		do {
			try await sync.runSyncPass(mode: .incremental)
			XCTFail("Expected the fetch failure to propagate")
		} catch {
			XCTAssertEqual(error as? TestSnippetSyncError, .fetchFailed)
		}
	}

	func test_runSyncPass_propagatesCheckpointFailure() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let client = FakeSnippetSyncClient()
		client.queuedFetch = SnippetChangeBatch(
			changedSnippets: [], deletedSnippetIDs: [],
			checkpoint: StubCheckpoint(), tokenExpired: false, mode: .incremental
		)
		client.checkpointError = TestSnippetSyncError.checkpointFailed
		let sync = SnippetSyncStore(store: store, client: client)

		do {
			try await sync.runSyncPass(mode: .incremental)
			XCTFail("Expected the checkpoint failure to propagate")
		} catch {
			XCTAssertEqual(error as? TestSnippetSyncError, .checkpointFailed)
		}
	}

	func test_runSyncPass_installsSubscriptionBeforeFetching() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let client = FakeSnippetSyncClient()
		client.subscriptionError = TestSnippetSyncError.subscriptionFailed
		let sync = SnippetSyncStore(store: store, client: client)

		do {
			try await sync.runSyncPass(mode: .forceFull)
			XCTFail("Expected the subscription failure to propagate")
		} catch {
			XCTAssertEqual(error as? TestSnippetSyncError, .subscriptionFailed)
		}
		XCTAssertEqual(client.fetchCallCount, 0)
	}

	func test_equivalentPushAcknowledgementClearsDirtyState() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		try store.upsert(Snippet(
			id: id,
			name: "local",
			content: "echo local",
			createdAt: .distantPast,
			updatedAt: .distantPast
		))
		let saved = try XCTUnwrap(store.snippets.first)
		let client = FakeSnippetSyncClient()
		client.pushResult = saved
		let sync = SnippetSyncStore(store: store, client: client)

		try await sync.runSyncPass(mode: .incremental)
		try await sync.runSyncPass(mode: .incremental)

		XCTAssertEqual(client.pushed.count, 1)
		XCTAssertTrue(store.locallyDirtySnippetIDs.isEmpty)
	}

	func testLocalEditSurvivesRestartAndForceFullMissingRemote() async throws {
		let directory = tempDir()
		let beforeRestart = SnippetStore(directory: directory)
		try beforeRestart.load()
		let snippet = Snippet(
			id: UUID(),
			name: "Deploy",
			content: "make deploy",
			createdAt: .distantPast,
			updatedAt: .distantPast
		)
		try beforeRestart.upsert(snippet)

		let afterRestart = SnippetStore(directory: directory)
		try afterRestart.load()
		let client = FakeSnippetSyncClient()
		let sync = SnippetSyncStore(store: afterRestart, client: client)

		try await sync.runSyncPass(mode: .forceFull)

		XCTAssertEqual(client.pushed.map(\.id), [snippet.id])
		XCTAssertEqual(afterRestart.snippets.map(\.id), [snippet.id])
		XCTAssertTrue(afterRestart.locallyDirtySnippetIDs.isEmpty)
		let confirmed = SnippetStore(directory: directory)
		try confirmed.load()
		XCTAssertTrue(confirmed.locallyDirtySnippetIDs.isEmpty)
	}

	func testFailedPushKeepsDirtyAcrossRestartForRetry() async throws {
		let directory = tempDir()
		let beforeFailure = SnippetStore(directory: directory)
		try beforeFailure.load()
		let snippet = Snippet(
			id: UUID(), name: "Deploy", content: "make deploy",
			createdAt: .distantPast, updatedAt: .distantPast
		)
		try beforeFailure.upsert(snippet)
		let failingClient = FakeSnippetSyncClient()
		failingClient.pushError = TestSnippetSyncError.pushFailed
		let failingSync = SnippetSyncStore(
			store: beforeFailure, client: failingClient
		)

		do {
			try await failingSync.runSyncPass(mode: .incremental)
			XCTFail("Expected the push failure to propagate")
		} catch {
			XCTAssertEqual(error as? TestSnippetSyncError, .pushFailed)
		}
		XCTAssertEqual(failingClient.pushAttempts, [snippet.id])
		XCTAssertEqual(beforeFailure.locallyDirtySnippetIDs, [snippet.id])

		let afterRestart = SnippetStore(directory: directory)
		try afterRestart.load()
		let recoveryClient = FakeSnippetSyncClient()
		let recoverySync = SnippetSyncStore(
			store: afterRestart, client: recoveryClient
		)

		try await recoverySync.runSyncPass(mode: .forceFull)

		XCTAssertEqual(recoveryClient.pushed.map(\.id), [snippet.id])
		XCTAssertTrue(afterRestart.locallyDirtySnippetIDs.isEmpty)
		let confirmed = SnippetStore(directory: directory)
		try confirmed.load()
		XCTAssertTrue(confirmed.locallyDirtySnippetIDs.isEmpty)
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

	func test_awaitableAndScheduledTriggers_shareOneLane() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let client = FakeSnippetSyncClient()
		client.fetchDelay = .milliseconds(50)
		let sync = SnippetSyncStore(store: store, client: client)

		sync.scheduleSyncPass(mode: .incremental)
		await waitUntil { client.fetchCallCount == 1 }
		try await sync.runSyncPass(mode: .forceFull)

		XCTAssertEqual(client.recordedModes, [.incremental, .forceFull])
		XCTAssertEqual(client.maximumActiveFetchCount, 1)
	}

	func test_followUpMode_preservesLastTriggerWinsSemantics() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let client = FakeSnippetSyncClient()
		client.fetchDelay = .milliseconds(50)
		let sync = SnippetSyncStore(store: store, client: client)

		let first = Task { try await sync.runSyncPass(mode: .incremental) }
		await waitUntil { client.fetchCallCount == 1 }
		let forceFull = Task { try await sync.runSyncPass(mode: .forceFull) }
		await Task.yield()
		let latest = Task { try await sync.runSyncPass(mode: .incremental) }
		try await first.value
		try await forceFull.value
		try await latest.value

		XCTAssertEqual(client.recordedModes, [.incremental, .incremental])
		XCTAssertEqual(client.maximumActiveFetchCount, 1)
	}

	func test_accountChangeSuspension_drainsBeforeForceFullResume() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let client = FakeSnippetSyncClient()
		client.suspendNextFetch = true
		let sync = SnippetSyncStore(store: store, client: client)

		let active = Task { try await sync.runSyncPass(mode: .incremental) }
		await waitUntil { client.fetchCallCount == 1 }
		var suspensionCompleted = false
		let suspension = Task {
			await sync.suspendForAccountChange()
			suspensionCompleted = true
		}
		for _ in 0..<20 { await Task.yield() }
		sync.scheduleSyncPass(mode: .incremental)

		XCTAssertFalse(suspensionCompleted)
		XCTAssertEqual(client.fetchCallCount, 1)

		client.releaseSuspendedFetch()
		_ = await active.result
		await suspension.value
		sync.resumeAfterAccountChange(identityChanged: true)
		await waitUntil { client.fetchCallCount == 2 }
		await sync.waitUntilIdle()

		XCTAssertEqual(client.recordedModes, [.incremental, .forceFull])
		XCTAssertEqual(client.maximumActiveFetchCount, 1)
	}

	func test_accountChangeGateCancelsZeroDelayTriggerBeforeItStarts() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let client = FakeSnippetSyncClient()
		let sync = SnippetSyncStore(store: store, client: client)

		sync.scheduleSyncPass(mode: .incremental)
		sync.beginAccountChangeSuspension()
		await sync.drainForAccountChange()
		for _ in 0..<20 { await Task.yield() }

		XCTAssertEqual(client.fetchCallCount, 0)

		sync.resumeAfterAccountChange(identityChanged: false)
		await waitUntil { client.fetchCallCount == 1 }
		await sync.waitUntilIdle()
		XCTAssertEqual(client.recordedModes, [.incremental])
	}

	func test_accountChangeCancellationStopsAfterNonCooperativeFetchReturns() async throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let localID = UUID()
		try store.upsert(Snippet(
			id: localID,
			name: "local",
			content: "echo local",
			createdAt: .distantPast,
			updatedAt: .distantPast
		))
		let remote = Snippet(
			id: UUID(),
			name: "remote",
			content: "echo remote",
			createdAt: .distantPast,
			updatedAt: .now,
			revision: 5
		)
		let client = FakeSnippetSyncClient()
		client.queuedFetch = SnippetChangeBatch(
			changedSnippets: [remote],
			deletedSnippetIDs: [],
			checkpoint: StubCheckpoint(),
			tokenExpired: false,
			mode: .incremental
		)
		client.suspendNextFetch = true
		let sync = SnippetSyncStore(store: store, client: client)

		let active = Task { try await sync.runSyncPass(mode: .incremental) }
		await waitUntil { client.fetchCallCount == 1 }
		sync.beginAccountChangeSuspension()
		let drain = Task { await sync.drainForAccountChange() }
		client.releaseSuspendedFetch()
		_ = await active.result
		await drain.value

		XCTAssertEqual(store.snippets.map(\.id), [localID])
		XCTAssertTrue(client.pushed.isEmpty)
		XCTAssertTrue(client.committedCheckpoints.isEmpty)
	}

	private func waitUntil(_ predicate: () -> Bool) async {
		for _ in 0..<1_000 {
			if predicate() { return }
			await Task.yield()
		}
		XCTFail("condition was not reached")
	}
}

private struct StubCheckpoint: SnippetSyncCheckpoint {
	let id = UUID()
}

private enum TestSnippetSyncError: Error, Equatable {
	case pushFailed
	case fetchFailed
	case checkpointFailed
	case subscriptionFailed
}

@MainActor
private final class FakeSnippetSyncClient: IncrementalSnippetSyncClient {
	var queuedFetch: SnippetChangeBatch?
	var pushed: [Snippet] = []
	var pushAttempts: [UUID] = []
	var pushResult: Snippet?
	var pushError: Error?
	var fetchError: Error?
	var checkpointError: Error?
	var subscriptionError: Error?
	var deleted: [UUID] = []
	var committedCheckpoints: [any SnippetSyncCheckpoint] = []
	var fetchCallCount = 0
	var fetchDelay: Duration = .zero
	var recordedModes: [SnippetSyncMode] = []
	var activeFetchCount = 0
	var maximumActiveFetchCount = 0
	var suspendNextFetch = false
	private var suspendedFetchContinuation: CheckedContinuation<Void, Never>?
	var subscriptions: Set<String> = []
	var hasTokens = false

	func preferredSnippetSyncMode() async -> SnippetSyncMode { .incremental }

	func fetchSnippetChanges() async throws -> SnippetChangeBatch {
		try await fetch(mode: .incremental)
	}

	func fetchSnippetSnapshotAndCheckpoint() async throws -> SnippetChangeBatch {
		try await fetch(mode: .forceFull)
	}

	private func fetch(mode: SnippetSyncMode) async throws -> SnippetChangeBatch {
		fetchCallCount += 1
		recordedModes.append(mode)
		activeFetchCount += 1
		maximumActiveFetchCount = max(maximumActiveFetchCount, activeFetchCount)
		defer { activeFetchCount -= 1 }
		if suspendNextFetch {
			suspendNextFetch = false
			await withCheckedContinuation { continuation in
				suspendedFetchContinuation = continuation
			}
		}
		if fetchDelay > .zero { try? await Task.sleep(for: fetchDelay) }
		if let fetchError { throw fetchError }
		return queuedFetch ?? SnippetChangeBatch(
			changedSnippets: [], deletedSnippetIDs: [],
			checkpoint: nil, tokenExpired: false, mode: mode
		)
	}

	func releaseSuspendedFetch() {
		suspendedFetchContinuation?.resume()
		suspendedFetchContinuation = nil
	}

	func commitSnippetCheckpoint(_ checkpoint: any SnippetSyncCheckpoint) async throws {
		if let checkpointError { throw checkpointError }
		committedCheckpoints.append(checkpoint)
	}

	func resetSnippetSyncState() async { hasTokens = false }
	func ensureSnippetSubscription() async throws {
		if let subscriptionError { throw subscriptionError }
		subscriptions.insert("snippet")
	}
	func deleteSnippetSubscription() async throws {
		subscriptions.remove("snippet")
	}
	func pushSnippet(_ s: Snippet) async throws -> Snippet {
		pushAttempts.append(s.id)
		if let pushError { throw pushError }
		pushed.append(s)
		if let pushResult { return pushResult }
		var copy = s
		copy.metadataUpdatedAt = Date()
		return copy
	}
	func deleteSnippet(id: UUID) async throws { deleted.append(id) }
	func hasAnySnippetSyncTokens() async -> Bool { hasTokens }
}
