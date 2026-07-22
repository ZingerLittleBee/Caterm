import XCTest
import SnippetSyncClient
@testable import SnippetStore

private struct LegacySnippetsEnvelope: Encodable {
	let schemaVersion: Int
	let snippets: [Snippet]
}

@MainActor
final class SnippetStoreTests: XCTestCase {
	private func tempDir() -> URL {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("snippet-store-tests-\(UUID().uuidString)")
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	func test_load_emptyOnFreshDir() throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		XCTAssertEqual(store.snippets, [])
	}

	func test_upsertCreate_persistsAcrossInstances() throws {
		let dir = tempDir()
		let store = SnippetStore(directory: dir)
		try store.load()
		let s = Snippet(id: UUID(), name: "ls", content: "ls -la",
		                createdAt: .now, updatedAt: .now)
		try store.upsert(s)

		let store2 = SnippetStore(directory: dir)
		try store2.load()
		XCTAssertEqual(store2.snippets.count, 1)
		XCTAssertEqual(store2.snippets.first?.name, "ls")
		XCTAssertEqual(store2.locallyDirtySnippetIDs, [s.id])
	}

	func test_upsertExisting_bumpsRevisionAndUpdatedAt() throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		let original = Snippet(id: id, name: "a", content: "x",
		                       createdAt: .distantPast, updatedAt: .distantPast,
		                       revision: 0)
		try store.upsert(original)
		var edited = original
		edited.name = "b"
		try store.upsert(edited)

		XCTAssertEqual(store.snippets.first?.name, "b")
		XCTAssertGreaterThan(store.snippets.first!.revision, 0)
		XCTAssertGreaterThan(store.snippets.first!.updatedAt, original.updatedAt)
	}

	func testLegacyEnvelopeWithoutDirtyIDsLoadsAsClean() throws {
		let directory = tempDir()
		let snippet = Snippet(
			id: UUID(), name: "Legacy", content: "echo legacy",
			createdAt: .distantPast, updatedAt: .distantPast
		)
		let data = try JSONEncoder().encode(
			LegacySnippetsEnvelope(schemaVersion: 1, snippets: [snippet])
		)
		try data.write(to: directory.appendingPathComponent("snippets.json"))

		let store = SnippetStore(directory: directory)
		try store.load()

		XCTAssertEqual(store.snippets.map(\.id), [snippet.id])
		XCTAssertTrue(store.locallyDirtySnippetIDs.isEmpty)
	}

	func test_delete_removesSnippetAndAddsToOutbox() throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		try store.upsert(Snippet(id: id, name: "a", content: "x",
		                         createdAt: .now, updatedAt: .now))
		try store.delete(id: id)
		XCTAssertEqual(store.snippets, [])
		XCTAssertTrue(store.pendingDeletedSnippetIDs.contains(id))
	}

	func test_outbox_persistsAcrossInstances() throws {
		let dir = tempDir()
		let store = SnippetStore(directory: dir)
		try store.load()
		let id = UUID()
		try store.upsert(Snippet(id: id, name: "a", content: "x",
		                         createdAt: .now, updatedAt: .now))
		try store.delete(id: id)

		let store2 = SnippetStore(directory: dir)
		try store2.load()
		XCTAssertTrue(store2.pendingDeletedSnippetIDs.contains(id))
	}

	func test_move_persistsOrderAcrossInstances() throws {
		let dir = tempDir()
		let store = SnippetStore(directory: dir)
		try store.load()
		for name in ["one", "two", "three"] {
			try store.upsert(Snippet(
				id: UUID(),
				name: name,
				content: name,
				createdAt: .now,
				updatedAt: .now
			))
		}

		try store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)

		let reloaded = SnippetStore(directory: dir)
		try reloaded.load()
		XCTAssertEqual(reloaded.snippets.map(\.name), ["two", "three", "one"])
	}

	func test_load_quarantinesCorruptSnippetFileWithoutReplacingMemory() throws {
		let dir = tempDir()
		let store = SnippetStore(directory: dir)
		let snippet = Snippet(
			id: UUID(),
			name: "safe",
			content: "echo safe",
			createdAt: .now,
			updatedAt: .now
		)
		try store.upsert(snippet)
		try Data("not-json".utf8).write(
			to: dir.appendingPathComponent("snippets.json"),
			options: .atomic
		)

		try store.load()

		XCTAssertEqual(store.snippets.map(\.id), [snippet.id])
		let quarantined = try FileManager.default.contentsOfDirectory(
			atPath: dir.path
		).filter { $0.hasPrefix("snippets.json.broken-") }
		XCTAssertEqual(quarantined.count, 1)
		XCTAssertFalse(FileManager.default.fileExists(
			atPath: dir.appendingPathComponent("snippets.json").path
		))
	}

	func test_load_quarantinesUnsupportedSchema() throws {
		let dir = tempDir()
		let data = try JSONSerialization.data(withJSONObject: [
			"schemaVersion": 99,
			"snippets": [],
			"locallyDirtySnippetIDs": [],
		])
		try data.write(to: dir.appendingPathComponent("snippets.json"))
		let store = SnippetStore(directory: dir)

		try store.load()

		XCTAssertTrue(store.snippets.isEmpty)
		let quarantined = try FileManager.default.contentsOfDirectory(
			atPath: dir.path
		).filter { $0.hasPrefix("snippets.json.broken-") }
		XCTAssertEqual(quarantined.count, 1)
	}
}

extension SnippetStoreTests {
	func test_search_matchesNameAndContentCaseInsensitive() throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		try store.upsert(Snippet(id: UUID(), name: "Docker", content: "docker ps",
		                         createdAt: .now, updatedAt: .now))
		try store.upsert(Snippet(id: UUID(), name: "List files", content: "ls -la",
		                         createdAt: .now, updatedAt: .now))

		XCTAssertEqual(store.search("docker").count, 1)
		XCTAssertEqual(store.search("DOCKER").count, 1)
		XCTAssertEqual(store.search("ps").count, 1)
		XCTAssertEqual(store.search("la").count, 1)
		XCTAssertEqual(store.search("nope").count, 0)
		XCTAssertEqual(store.search("").count, 2)
	}

	func test_applyRemoteUpsert_replacesExistingByID() throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		try store.upsert(Snippet(id: id, name: "old", content: "x",
		                         createdAt: .now, updatedAt: Date(timeIntervalSince1970: 1),
		                         revision: 1))
		// Server-authoritative version arrives with higher revision.
		let remote = Snippet(id: id, name: "new", content: "y",
		                     createdAt: .now, updatedAt: Date(timeIntervalSince1970: 100),
		                     revision: 5)
		let applied = try store.applyRemote(remote)
		XCTAssertTrue(applied, "remote with higher revision must be applied")
		XCTAssertEqual(store.snippets.first?.name, "new")
		XCTAssertEqual(store.snippets.first?.revision, 5)
	}

	func test_applyRemote_skipsWhenLocalRevisionHigher() throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		// Local has been edited and has a higher revision than the just-pushed copy.
		try store.upsert(Snippet(id: id, name: "edited-locally", content: "new-content",
		                         createdAt: .now, updatedAt: Date(timeIntervalSince1970: 200),
		                         revision: 3))
		// Simulate the server echo of the older push (lower revision).
		let savedByServer = Snippet(id: id, name: "pushed-copy", content: "old-content",
		                            createdAt: .now, updatedAt: Date(timeIntervalSince1970: 50),
		                            revision: 2)
		let applied = try store.applyRemote(savedByServer)
		XCTAssertFalse(applied, "local with higher revision must not be overwritten")
		XCTAssertEqual(store.snippets.first?.name, "edited-locally",
		               "local edit must survive the applyRemote call")
		XCTAssertEqual(store.snippets.first?.revision, 3)
	}

	func test_applyRemote_skipsWhenLocalRevisionHigher_onTiedRevisionLaterUpdatedAt() throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		let localUpdatedAt = Date(timeIntervalSince1970: 300)
		let remoteUpdatedAt = Date(timeIntervalSince1970: 100)
		try store.upsert(Snippet(id: id, name: "local", content: "c",
		                         createdAt: .now, updatedAt: localUpdatedAt,
		                         revision: 2))
		// Manually set snippet to keep revision at 2 (upsert bumps it; use applyRemote to seed).
		let seed = Snippet(id: id, name: "local", content: "c",
		                   createdAt: .now, updatedAt: localUpdatedAt,
		                   revision: 2)
		_ = try store.applyRemote(seed)  // set to known state

		let remote = Snippet(id: id, name: "remote", content: "r",
		                     createdAt: .now, updatedAt: remoteUpdatedAt,
		                     revision: 2)
		let applied = try store.applyRemote(remote)
		XCTAssertFalse(applied, "local with same revision but later updatedAt must win")
		XCTAssertEqual(store.snippets.first?.name, "local")
	}

	func test_applyRemote_cloudWinsEqualVersionContentTie() throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		let timestamp = Date(timeIntervalSince1970: 100)
		let local = Snippet(
			id: id,
			name: "local",
			content: "local-content",
			createdAt: timestamp,
			updatedAt: timestamp,
			revision: 2,
			metadataUpdatedAt: timestamp
		)
		_ = try store.applyRemote(local)
		let remote = Snippet(
			id: id,
			name: "remote",
			content: "remote-content",
			createdAt: timestamp,
			updatedAt: timestamp,
			revision: 2,
			metadataUpdatedAt: timestamp
		)

		let applied = try store.applyRemote(remote)

		XCTAssertTrue(applied)
		XCTAssertEqual(store.snippets.first?.name, "remote")
	}

	func test_applyRemoteTombstone_removesEvenIfDirty() throws {
		let store = SnippetStore(directory: tempDir())
		try store.load()
		let id = UUID()
		try store.upsert(Snippet(id: id, name: "a", content: "b",
		                         createdAt: .now, updatedAt: .now))
		try store.applyRemoteTombstone(id: id)
		XCTAssertTrue(store.snippets.isEmpty)
		// Tombstone application also clears the local outbox entry if any.
		XCTAssertFalse(store.pendingDeletedSnippetIDs.contains(id))
	}

	func test_wipeLocal_clearsBothFiles() throws {
		let dir = tempDir()
		let store = SnippetStore(directory: dir)
		try store.load()
		let id = UUID()
		try store.upsert(Snippet(id: id, name: "a", content: "b",
		                         createdAt: .now, updatedAt: .now))
		try store.delete(id: id)
		try store.wipeLocal()

		let store2 = SnippetStore(directory: dir)
		try store2.load()
		XCTAssertEqual(store2.snippets, [])
		XCTAssertEqual(store2.pendingDeletedSnippetIDs, [])
	}
}
