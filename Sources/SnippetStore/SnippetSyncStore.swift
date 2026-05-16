import Foundation
import SnippetSyncClient
import os

@MainActor
public final class SnippetSyncStore: ObservableObject {
	private static let log = Logger(subsystem: "com.caterm.app", category: "snippet-sync")
	private let store: SnippetStore
	private let client: any IncrementalSnippetSyncClient

	private var locallyDirty: Set<UUID> = []
	/// Non-nil while a fire-and-forget sync pass Task is in flight.
	private var inFlight: Task<Void, Never>?
	/// At most one follow-up mode is queued while `inFlight` is running.
	private var queuedFollowUp: SnippetSyncMode?
	private var debounce: Task<Void, Never>?

	public init(store: SnippetStore, client: any IncrementalSnippetSyncClient) {
		self.store = store
		self.client = client
	}

	public func markDirty(_ id: UUID) {
		locallyDirty.insert(id)
	}

	/// Fire-and-forget trigger with single in-flight + at-most-one queued
	/// follow-up coalescing.  Multiple rapid calls collapse into ≤ 2 passes.
	public func scheduleSyncPass(mode: SnippetSyncMode = .incremental, debounceMs: Int = 0) {
		debounce?.cancel()
		debounce = Task { @MainActor [weak self] in
			if debounceMs > 0 {
				try? await Task.sleep(for: .milliseconds(debounceMs))
				guard !Task.isCancelled else { return }
			}
			self?.launchOrCoalesce(mode: mode)
		}
	}

	private func launchOrCoalesce(mode: SnippetSyncMode) {
		guard inFlight == nil else {
			// Already running — queue at most one follow-up.
			queuedFollowUp = mode
			return
		}
		inFlight = Task { @MainActor [weak self] in
			guard let self else { return }
			await self.executeSyncPass(mode: mode)
			self.inFlight = nil
			if let next = self.queuedFollowUp {
				self.queuedFollowUp = nil
				self.launchOrCoalesce(mode: next)
			}
		}
	}

	/// Directly awaitable sync pass used by callers that need to wait for
	/// completion (e.g., tests, forced triggers from the UI).
	/// Does NOT go through the coalescing queue.
	public func runSyncPass(mode: SnippetSyncMode) async {
		await executeSyncPass(mode: mode)
	}

	// MARK: - Core pass

	private func executeSyncPass(mode: SnippetSyncMode) async {
		do {
			// Step 1 — drain pending-delete outbox before fetch.
			let pendingDeletes = store.pendingDeletedSnippetIDs
			for id in pendingDeletes {
				do {
					try await client.deleteSnippet(id: id)
					try store.clearOutboxEntry(id)
				} catch {
					Self.log.error("deleteSnippet failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
					// Leave in outbox; next pass retries.
				}
			}

			// Step 2 — fetch.
			let batch: SnippetChangeBatch
			switch mode {
			case .forceFull:
				batch = try await client.fetchSnippetSnapshotAndCheckpoint()
			case .incremental:
				batch = try await client.fetchSnippetChanges()
			}

			if batch.tokenExpired {
				Self.log.info("token expired — falling back to forceFull")
				let snapshot = try await client.fetchSnippetSnapshotAndCheckpoint()
				await applyBatch(snapshot)
				if let cp = snapshot.checkpoint {
					try await client.commitSnippetCheckpoint(cp)
				}
				return
			}

			// Step 3 — apply then commit.
			await applyBatch(batch)
			if let cp = batch.checkpoint {
				try await client.commitSnippetCheckpoint(cp)
			}
		} catch {
			Self.log.error("snippet sync pass failed: \(error.localizedDescription, privacy: .public)")
		}
	}

	// MARK: - Force-full periodic timer

	private var forceFullTimer: Task<Void, Never>?

	public func startForceFullTimer() {
		forceFullTimer?.cancel()
		forceFullTimer = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(60 * 60))
				guard !Task.isCancelled, let self else { return }
				self.scheduleSyncPass(mode: .forceFull)
			}
		}
	}

	public func stopForceFullTimer() {
		forceFullTimer?.cancel()
		forceFullTimer = nil
	}

	private func applyBatch(_ batch: SnippetChangeBatch) async {
		let ops: [SnippetSyncOperation]
		switch batch.mode {
		case .forceFull:
			ops = SnippetSyncReconciler.reconcileFullSnapshot(
				local: store.snippets,
				remote: batch.changedSnippets,
				locallyDirty: locallyDirty
			)
		case .incremental:
			ops = SnippetSyncReconciler.reconcileDelta(
				local: store.snippets,
				changedSnippets: batch.changedSnippets,
				deletedIDs: batch.deletedSnippetIDs,
				locallyDirty: locallyDirty
			)
		}
		for op in ops {
			switch op {
			case .applyRemote(let s):
				let applied = (try? store.applyRemote(s)) ?? false
				if applied {
					locallyDirty.remove(s.id)
				}
			case .applyTombstone(let id):
				try? store.applyRemoteTombstone(id: id)
				locallyDirty.remove(id)
			case .pushLocal(let s):
				do {
					let saved = try await client.pushSnippet(s)
					do {
						let applied = try store.applyRemote(saved)
						// Only clear the dirty flag when the pushed copy was
						// actually stored.  If the user edited the snippet
						// between the push start and its completion, the local
						// revision is now higher than `saved`, applyRemote
						// returned false, and we must keep the dirty flag so
						// the next pass re-pushes the newer edit.
						if applied {
							locallyDirty.remove(s.id)
						}
					} catch {
						Self.log.error("applyRemote after push failed for \(s.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
					}
				} catch {
					Self.log.error("pushSnippet failed for \(s.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
					// Stay dirty; next pass retries.
				}
			}
		}
	}
}
