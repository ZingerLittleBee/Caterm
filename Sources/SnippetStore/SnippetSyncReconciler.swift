import Foundation
import MergeDecision
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
		let localIndex = SnippetMergePolicy.makeIdentityIndex(local)
		var touchedLocalIDs: Set<UUID> = []

		// Tombstones first — terminal.
		let tombstoneSet = Set(deletedIDs)
		for id in deletedIDs {
			ops.append(.applyTombstone(id: id))
		}

		for remote in changedSnippets {
			if tombstoneSet.contains(remote.id) { continue }
			guard let l = SnippetMergePolicy.match(remote, in: localIndex) else {
				ops.append(.applyRemote(remote))
				continue
			}
			touchedLocalIDs.insert(l.id)
			switch SnippetMergePolicy.decide(local: l, incoming: remote) {
			case .incoming: ops.append(.applyRemote(remote))
			case .local:
				if locallyDirty.contains(l.id) {
					ops.append(.pushLocal(l))
				}
				// not dirty — no push needed.
			case .equivalent: break
			}
		}

		// Locally dirty snippets that the server has not changed in this delta.
		for id in locallyDirty {
			if tombstoneSet.contains(id) { continue }
			if touchedLocalIDs.contains(id) { continue }
			if let l = localIndex.match(localID: id, serverID: nil) {
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
		let localIndex = SnippetMergePolicy.makeIdentityIndex(local)
		var matchedLocalIDs: Set<UUID> = []

		for r in remote {
			guard let l = SnippetMergePolicy.match(r, in: localIndex) else {
				ops.append(.applyRemote(r))
				continue
			}
			matchedLocalIDs.insert(l.id)
			switch SnippetMergePolicy.decide(local: l, incoming: r) {
			case .incoming: ops.append(.applyRemote(r))
			case .local:
				if locallyDirty.contains(l.id) {
					ops.append(.pushLocal(l))
				}
			case .equivalent: break
			}
		}
		for l in local where !matchedLocalIDs.contains(l.id) {
			if locallyDirty.contains(l.id) {
				ops.append(.pushLocal(l))
			} else {
				ops.append(.applyTombstone(id: l.id))
			}
		}
		return ops
	}
}
