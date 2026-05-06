import Foundation
import SnippetSyncClient

public enum SnippetSyncReconciler {
	/// Incremental delta reconciliation. `locallyDirty` IDs are local
	/// snippets that have been edited since their last successful push;
	/// they may need to be pushed if the remote either matches or lags.
	public static func reconcileDelta(
		local: [Snippet],
		changedSnippets: [Snippet],
		deletedIDs: [UUID],
		locallyDirty: Set<UUID>
	) -> [SnippetSyncOperation] {
		var ops: [SnippetSyncOperation] = []
		let localById = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })

		// Tombstones first — terminal.
		let tombstoneSet = Set(deletedIDs)
		for id in deletedIDs {
			ops.append(.applyTombstone(id: id))
		}

		for remote in changedSnippets {
			if tombstoneSet.contains(remote.id) { continue }
			guard let l = localById[remote.id] else {
				ops.append(.applyRemote(remote))
				continue
			}
			switch compare(local: l, remote: remote) {
			case .remoteWins: ops.append(.applyRemote(remote))
			case .localWins:
				if locallyDirty.contains(l.id) {
					ops.append(.pushLocal(l))
				}
				// else: parity, no-op.
			case .parity: break
			}
		}

		// Locally dirty snippets that the server has not changed in this delta.
		let touchedRemoteIDs = Set(changedSnippets.map(\.id))
		for id in locallyDirty {
			if tombstoneSet.contains(id) { continue }
			if touchedRemoteIDs.contains(id) { continue }
			if let l = localById[id] {
				ops.append(.pushLocal(l))
			}
		}
		return ops
	}

	/// Force-full snapshot reconciliation. The remote list is authoritative;
	/// anything missing locally is added, anything extra locally is tombstoned
	/// (unless it's locally dirty — meaning it was created locally and not yet
	/// pushed).
	public static func reconcileFullSnapshot(
		local: [Snippet],
		remote: [Snippet],
		locallyDirty: Set<UUID>
	) -> [SnippetSyncOperation] {
		var ops: [SnippetSyncOperation] = []
		let remoteById = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
		let localById = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })

		for r in remote {
			guard let l = localById[r.id] else {
				ops.append(.applyRemote(r))
				continue
			}
			switch compare(local: l, remote: r) {
			case .remoteWins: ops.append(.applyRemote(r))
			case .localWins:
				if locallyDirty.contains(l.id) {
					ops.append(.pushLocal(l))
				}
			case .parity: break
			}
		}
		for l in local where remoteById[l.id] == nil {
			if locallyDirty.contains(l.id) {
				ops.append(.pushLocal(l))
			} else {
				ops.append(.applyTombstone(id: l.id))
			}
		}
		return ops
	}

	// MARK: - Internals

	private enum CompareOutcome { case remoteWins, localWins, parity }

	private static func compare(local: Snippet, remote: Snippet) -> CompareOutcome {
		if remote.revision > local.revision { return .remoteWins }
		if remote.revision < local.revision { return .localWins }
		// Equal revision — compare metadataUpdatedAt (server-authoritative).
		switch (remote.metadataUpdatedAt, local.metadataUpdatedAt) {
		case let (.some(r), .some(l)):
			if r > l { return .remoteWins }
			if r < l { return .localWins }
		case (.some, nil): return .remoteWins
		case (nil, .some): return .localWins
		case (nil, nil): break
		}
		// Final tie-break: updatedAt, then cloud wins.
		if remote.updatedAt > local.updatedAt { return .remoteWins }
		if remote.updatedAt < local.updatedAt { return .localWins }
		return .parity
	}
}
