import Foundation
import SnippetStore
import SnippetSyncClient
@testable import CatermMobile
import XCTest

@MainActor
final class MobileSnippetSyncRuntimeTests: XCTestCase {
	func testSnippetChangeReachesFreshStoreAndDeletionUsesIndependentCheckpoints() async throws {
		let cloud = MobileSnippetTestCloud()
		let firstDirectory = temporaryDirectory(named: "first")
		let firstStore = SnippetStore(directory: firstDirectory)
		try firstStore.load()
		let firstClient = MobileSnippetTestClient(cloud: cloud)
		let firstRuntime = makeRuntime(store: firstStore, client: firstClient)
		let snippet = Snippet(
			id: UUID(),
			name: "Deploy",
			content: "printf persisted-snippet",
			createdAt: Date(timeIntervalSince1970: 1_700_000_000),
			updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
		)
		try firstStore.upsert(snippet)

		await firstRuntime.launch()

		let acknowledged = try XCTUnwrap(firstStore.snippets.first)
		XCTAssertFalse(firstStore.locallyDirtySnippetIDs.contains(snippet.id))
		XCTAssertNotNil(acknowledged.metadataUpdatedAt)

		let secondDirectory = temporaryDirectory(named: "second")
		let secondStore = SnippetStore(directory: secondDirectory)
		try secondStore.load()
		let secondClient = MobileSnippetTestClient(cloud: cloud)
		let secondRuntime = makeRuntime(store: secondStore, client: secondClient)

		await secondRuntime.launch()

		XCTAssertEqual(secondStore.snippets, [acknowledged])
		let firstCommits = await firstClient.committedSequences()
		let initialSecondCommits = await secondClient.committedSequences()
		XCTAssertEqual(firstCommits, [0])
		XCTAssertEqual(initialSecondCommits, [1])

		let reloadedSecondStore = SnippetStore(directory: secondDirectory)
		try reloadedSecondStore.load()
		XCTAssertEqual(reloadedSecondStore.snippets, [acknowledged])

		try firstStore.delete(id: snippet.id)
		await firstRuntime.sync.runSyncPass(mode: .incremental)
		await secondRuntime.becameActive()

		XCTAssertTrue(secondStore.snippets.isEmpty)
		let finalSecondCommits = await secondClient.committedSequences()
		XCTAssertEqual(finalSecondCommits, [1, 2])
		let reloadedAfterDeletion = SnippetStore(directory: secondDirectory)
		try reloadedAfterDeletion.load()
		XCTAssertTrue(reloadedAfterDeletion.snippets.isEmpty)
	}

	func testCloudPushReportsNewDataAndInstallsSubscription() async throws {
		let cloud = MobileSnippetTestCloud()
		let producer = MobileSnippetTestClient(cloud: cloud)
		let remote = Snippet(
			id: UUID(),
			name: "Remote",
			content: "echo remote",
			createdAt: .distantPast,
			updatedAt: .distantPast
		)
		_ = try await producer.pushSnippet(remote)

		let store = SnippetStore(directory: temporaryDirectory(named: "push"))
		try store.load()
		let client = MobileSnippetTestClient(cloud: cloud)
		let runtime = makeRuntime(store: store, client: client)

		let result = await runtime.receivedCloudKitPush()

		XCTAssertEqual(result, .newData)
		XCTAssertEqual(store.snippets.map(\.id), [remote.id])
		let subscriptionInstalled = await client.subscriptionInstalled()
		XCTAssertTrue(subscriptionInstalled)
	}

	func testSignedOutMutationStaysDurableWithoutStartingNetworkWork() async throws {
		let cloud = MobileSnippetTestCloud()
		let store = SnippetStore(directory: temporaryDirectory(named: "signed-out"))
		try store.load()
		let client = MobileSnippetTestClient(cloud: cloud)
		let sync = SnippetSyncStore(store: store, client: client)
		let runtime = MobileSnippetSyncRuntime(
			store: store,
			sync: sync,
			client: client,
			isSignedIn: { false },
			refreshAccount: {}
		)
		let snippet = Snippet(
			id: UUID(), name: "Offline", content: "echo offline",
			createdAt: .distantPast, updatedAt: .distantPast
		)
		try store.upsert(snippet)

		runtime.scheduleLocalMutation(debounceMs: 0)
		for _ in 0..<20 { await Task.yield() }

		XCTAssertEqual(runtime.state, .signedOut)
		XCTAssertEqual(store.locallyDirtySnippetIDs, [snippet.id])
		let fetchCount = await client.fetchRequestCount()
		XCTAssertEqual(fetchCount, 0)
	}

	private func makeRuntime(
		store: SnippetStore,
		client: MobileSnippetTestClient
	) -> MobileSnippetSyncRuntime {
		let sync = SnippetSyncStore(store: store, client: client)
		return MobileSnippetSyncRuntime(
			store: store,
			sync: sync,
			client: client,
			isSignedIn: { true },
			refreshAccount: {}
		)
	}

	private func temporaryDirectory(named name: String) -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("mobile-snippet-runtime-\(name)-\(UUID().uuidString)")
		try? FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		return directory
	}
}

private struct MobileSnippetTestCheckpoint: SnippetSyncCheckpoint {
	let id = UUID()
	let sequence: Int
}

private actor MobileSnippetTestCloud {
	private enum Event {
		case changed(Snippet)
		case deleted(UUID)
	}

	private var records: [UUID: Snippet] = [:]
	private var events: [Event] = []

	func push(_ snippet: Snippet) -> Snippet {
		var saved = snippet
		saved.serverId = snippet.serverId ?? snippet.id.uuidString
		saved.metadataUpdatedAt = Date()
		records[saved.id] = saved
		events.append(.changed(saved))
		return saved
	}

	func delete(_ id: UUID) {
		records.removeValue(forKey: id)
		events.append(.deleted(id))
	}

	func snapshot() -> (snippets: [Snippet], sequence: Int) {
		(Array(records.values).sorted { $0.id.uuidString < $1.id.uuidString }, events.count)
	}

	func changes(after sequence: Int) -> (
		changed: [Snippet],
		deleted: [UUID],
		sequence: Int
	) {
		var changed: [Snippet] = []
		var deleted: [UUID] = []
		for event in events.dropFirst(sequence) {
			switch event {
			case let .changed(snippet):
				changed.append(snippet)
			case let .deleted(id):
				deleted.append(id)
			}
		}
		return (changed, deleted, events.count)
	}
}

private actor MobileSnippetTestClient: IncrementalSnippetSyncClient {
	private let cloud: MobileSnippetTestCloud
	private var sequence = 0
	private var commits: [Int] = []
	private var hasSubscription = false
	private var fetchRequests = 0

	init(cloud: MobileSnippetTestCloud) {
		self.cloud = cloud
	}

	func preferredSnippetSyncMode() async -> SnippetSyncMode { .forceFull }

	func fetchSnippetChanges() async throws -> SnippetChangeBatch {
		fetchRequests += 1
		let delta = await cloud.changes(after: sequence)
		return SnippetChangeBatch(
			changedSnippets: delta.changed,
			deletedSnippetIDs: delta.deleted,
			checkpoint: MobileSnippetTestCheckpoint(sequence: delta.sequence),
			tokenExpired: false,
			mode: .incremental
		)
	}

	func fetchSnippetSnapshotAndCheckpoint() async throws -> SnippetChangeBatch {
		fetchRequests += 1
		let snapshot = await cloud.snapshot()
		return SnippetChangeBatch(
			changedSnippets: snapshot.snippets,
			deletedSnippetIDs: [],
			checkpoint: MobileSnippetTestCheckpoint(sequence: snapshot.sequence),
			tokenExpired: false,
			mode: .forceFull
		)
	}

	func commitSnippetCheckpoint(_ checkpoint: any SnippetSyncCheckpoint) async throws {
		guard let checkpoint = checkpoint as? MobileSnippetTestCheckpoint else {
			return
		}
		sequence = checkpoint.sequence
		commits.append(checkpoint.sequence)
	}

	func resetSnippetSyncState() async {
		sequence = 0
		commits = []
	}

	func ensureSnippetSubscription() async throws {
		hasSubscription = true
	}

	func deleteSnippetSubscription() async throws {
		hasSubscription = false
	}

	func pushSnippet(_ snippet: Snippet) async throws -> Snippet {
		await cloud.push(snippet)
	}

	func deleteSnippet(id: UUID) async throws {
		await cloud.delete(id)
	}

	func hasAnySnippetSyncTokens() async -> Bool { sequence > 0 }

	func committedSequences() -> [Int] { commits }
	func subscriptionInstalled() -> Bool { hasSubscription }
	func fetchRequestCount() -> Int { fetchRequests }
}
