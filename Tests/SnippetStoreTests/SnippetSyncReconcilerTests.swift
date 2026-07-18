import XCTest
import SnippetSyncClient
@testable import SnippetStore

final class SnippetSyncReconcilerTests: XCTestCase {
	private func snip(
		id: UUID = UUID(),
		name: String = "n",
		revision: Int = 0,
		metaUpdated: Date? = nil,
		updatedAt: Date = Date(timeIntervalSince1970: 0)
	) -> Snippet {
		Snippet(
			id: id,
			name: name,
			content: "c",
			createdAt: .distantPast,
			updatedAt: updatedAt,
			revision: revision,
			metadataUpdatedAt: metaUpdated
		)
	}

	func test_remoteHigherRevision_appliesRemote() {
		let id = UUID()
		let local = snip(id: id, revision: 1)
		let remote = snip(id: id, name: "remote", revision: 2)
		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local], changedSnippets: [remote], deletedIDs: [],
			locallyDirty: []
		)
		XCTAssertEqual(ops, [.applyRemote(remote)])
	}

	func test_revisionPrecedesNewerLocalTimestamps() {
		let id = UUID()
		let local = snip(
			id: id,
			revision: 1,
			metaUpdated: Date(timeIntervalSince1970: 300),
			updatedAt: Date(timeIntervalSince1970: 300)
		)
		let remote = snip(
			id: id,
			name: "remote",
			revision: 2,
			metaUpdated: Date(timeIntervalSince1970: 100),
			updatedAt: Date(timeIntervalSince1970: 100)
		)

		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local],
			changedSnippets: [remote],
			deletedIDs: [],
			locallyDirty: []
		)

		XCTAssertEqual(ops, [.applyRemote(remote)])
	}

	func test_remoteLowerRevision_pushesLocalIfDirty() {
		let id = UUID()
		let local = snip(id: id, revision: 5)
		let remote = snip(id: id, name: "stale", revision: 2)
		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local], changedSnippets: [remote], deletedIDs: [],
			locallyDirty: [id]
		)
		XCTAssertEqual(ops, [.pushLocal(local)])
	}

	func test_remoteLowerRevision_notDirty_isNoOp() {
		let id = UUID()
		let local = snip(id: id, revision: 5)
		let remote = snip(id: id, name: "stale", revision: 2)
		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local], changedSnippets: [remote], deletedIDs: [],
			locallyDirty: []
		)
		XCTAssertEqual(ops, [])
	}

	func test_remoteEqualRevision_metadataUpdatedAtBreaksTie_cloudWins() {
		let id = UUID()
		let local = snip(id: id, revision: 1, metaUpdated: Date(timeIntervalSince1970: 100))
		let remote = snip(id: id, name: "remote", revision: 1, metaUpdated: Date(timeIntervalSince1970: 200))
		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local], changedSnippets: [remote], deletedIDs: [],
			locallyDirty: []
		)
		XCTAssertEqual(ops, [.applyRemote(remote)])
	}

	func test_metadataPresenceBeatsMissingIncomingMetadata() {
		let id = UUID()
		let local = snip(
			id: id,
			revision: 1,
			metaUpdated: Date(timeIntervalSince1970: 100)
		)
		let remote = snip(id: id, name: "remote", revision: 1)

		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local],
			changedSnippets: [remote],
			deletedIDs: [],
			locallyDirty: [id]
		)

		XCTAssertEqual(ops, [.pushLocal(local)])
	}

	func test_newerLocalMetadataDatePushesWhenDirty() {
		let id = UUID()
		let local = snip(
			id: id,
			revision: 1,
			metaUpdated: Date(timeIntervalSince1970: 200)
		)
		let remote = snip(
			id: id,
			name: "remote",
			revision: 1,
			metaUpdated: Date(timeIntervalSince1970: 100)
		)

		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local],
			changedSnippets: [remote],
			deletedIDs: [],
			locallyDirty: [id]
		)

		XCTAssertEqual(ops, [.pushLocal(local)])
	}

	func test_updatedAtBreaksTieAfterEqualMetadata() {
		let id = UUID()
		let metadataDate = Date(timeIntervalSince1970: 100)
		let local = snip(
			id: id,
			revision: 1,
			metaUpdated: metadataDate,
			updatedAt: Date(timeIntervalSince1970: 100)
		)
		let remote = snip(
			id: id,
			name: "remote",
			revision: 1,
			metaUpdated: metadataDate,
			updatedAt: Date(timeIntervalSince1970: 200)
		)

		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local],
			changedSnippets: [remote],
			deletedIDs: [],
			locallyDirty: []
		)

		XCTAssertEqual(ops, [.applyRemote(remote)])
	}

	func test_newerLocalUpdatedAtPushesWhenDirty() {
		let id = UUID()
		let metadataDate = Date(timeIntervalSince1970: 100)
		let local = snip(
			id: id,
			revision: 1,
			metaUpdated: metadataDate,
			updatedAt: Date(timeIntervalSince1970: 200)
		)
		let remote = snip(
			id: id,
			name: "remote",
			revision: 1,
			metaUpdated: metadataDate,
			updatedAt: Date(timeIntervalSince1970: 100)
		)

		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local],
			changedSnippets: [remote],
			deletedIDs: [],
			locallyDirty: [id]
		)

		XCTAssertEqual(ops, [.pushLocal(local)])
	}

	func test_parity_emitsNoOps() {
		let id = UUID()
		let meta = Date(timeIntervalSince1970: 100)
		let updated = Date(timeIntervalSince1970: 200)
		let local = snip(id: id, revision: 1, metaUpdated: meta, updatedAt: updated)
		let remote = snip(id: id, revision: 1, metaUpdated: meta, updatedAt: updated)
		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local], changedSnippets: [remote], deletedIDs: [],
			locallyDirty: []
		)
		XCTAssertEqual(ops, [])
	}

	func test_equalVersionWithDivergentContentAppliesCloudTieBreak() {
		let id = UUID()
		let timestamp = Date(timeIntervalSince1970: 100)
		let local = snip(
			id: id,
			name: "local",
			revision: 1,
			metaUpdated: timestamp,
			updatedAt: timestamp
		)
		let remote = snip(
			id: id,
			name: "remote",
			revision: 1,
			metaUpdated: timestamp,
			updatedAt: timestamp
		)

		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local],
			changedSnippets: [remote],
			deletedIDs: [],
			locallyDirty: []
		)

		XCTAssertEqual(ops, [.applyRemote(remote)])
	}

	func test_remoteTombstone_emitsApplyTombstone_evenIfLocalDirty() {
		let id = UUID()
		let local = snip(id: id, revision: 99)
		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local], changedSnippets: [], deletedIDs: [id],
			locallyDirty: [id]
		)
		XCTAssertEqual(ops, [.applyTombstone(id: id)])
	}

	func test_localOnly_dirty_pushesIfNotInRemote() {
		let id = UUID()
		let local = snip(id: id, revision: 1)
		let ops = SnippetSyncReconciler.reconcileDelta(
			local: [local], changedSnippets: [], deletedIDs: [],
			locallyDirty: [id]
		)
		XCTAssertEqual(ops, [.pushLocal(local)])
	}

	func test_forceFullSnapshot_remoteAuthoritative_localOnlyDeleted() {
		let id1 = UUID(), id2 = UUID()
		let local = [snip(id: id1, revision: 1), snip(id: id2, revision: 1)]
		let remote = [snip(id: id1, name: "kept", revision: 2)]
		let ops = SnippetSyncReconciler.reconcileFullSnapshot(
			local: local, remote: remote, locallyDirty: []
		)
		// id1 → applyRemote (newer); id2 → applyTombstone (not in snapshot).
		XCTAssertTrue(ops.contains(.applyRemote(remote[0])))
		XCTAssertTrue(ops.contains(.applyTombstone(id: id2)))
	}

	func test_forceFullSnapshot_locallyDirtyAbsentRemote_pushedNotDeleted() {
		let id = UUID()
		let local = [snip(id: id, revision: 1)]
		let ops = SnippetSyncReconciler.reconcileFullSnapshot(
			local: local, remote: [], locallyDirty: [id]
		)
		// New local snippet not yet pushed — must push, not delete.
		XCTAssertEqual(ops, [.pushLocal(local[0])])
	}

	func test_forceFullSnapshot_emptyInputs_emitsNoOps() {
		let ops = SnippetSyncReconciler.reconcileFullSnapshot(
			local: [], remote: [], locallyDirty: []
		)
		XCTAssertEqual(ops, [])
	}
}
