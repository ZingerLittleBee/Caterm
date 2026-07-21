import Foundation
import SnippetSyncClient
import SyncScheduler
import os

@MainActor
public final class SnippetSyncStore: ObservableObject {
	private static let log = Logger(subsystem: "com.caterm.app", category: "snippet-sync")
	private let store: SnippetStore
	private let client: any IncrementalSnippetSyncClient

	private var debounce: Task<Void, Never>?
	private var debouncedMode: SnippetSyncMode?
	private var isSuspendedForAccountChange = false
	private var pendingWhileSuspended: SnippetSyncMode?
	private lazy var scheduler = SyncScheduler<SnippetSyncMode>(
		strategy: .coalescing { _, incoming in incoming },
		operation: { [weak self] mode in
			try await self?.executeSyncPass(mode: mode)
		}
	)

	public init(store: SnippetStore, client: any IncrementalSnippetSyncClient) {
		self.store = store
		self.client = client
	}

	/// Fire-and-forget trigger with single in-flight + at-most-one queued
	/// follow-up coalescing.  Multiple rapid calls collapse into ≤ 2 passes.
	public func scheduleSyncPass(mode: SnippetSyncMode = .incremental, debounceMs: Int = 0) {
		guard !isSuspendedForAccountChange else {
			pendingWhileSuspended = mode
			return
		}
		debounce?.cancel()
		guard debounceMs > 0 else {
			debounce = nil
			debouncedMode = nil
			_ = scheduler.submit(mode)
			return
		}
		debouncedMode = mode
		debounce = Task { @MainActor [weak self] in
			try? await Task.sleep(for: .milliseconds(debounceMs))
			guard !Task.isCancelled, let self,
			      !self.isSuspendedForAccountChange else { return }
			self.debouncedMode = nil
			self.debounce = nil
			_ = self.scheduler.submit(mode)
		}
	}

	/// Directly awaitable sync pass used by callers that need to wait for
	/// completion (e.g., tests, forced triggers from the UI).
	/// Uses the same single-flight queue as fire-and-forget triggers.
	public func runSyncPass(mode: SnippetSyncMode) async {
		guard !isSuspendedForAccountChange else {
			pendingWhileSuspended = mode
			return
		}
		do {
			try await scheduler.submit(mode).value
		} catch is CancellationError {
			// Account and lifecycle cancellation is an expected terminal state.
		} catch {
			Self.log.error("snippet scheduler failed: \(error.localizedDescription, privacy: .public)")
		}
	}

	/// Close the snippet lane synchronously before any account-scoped store is
	/// drained. A pending debounce is retained for same-identity recovery.
	public func beginAccountChangeSuspension() {
		guard !isSuspendedForAccountChange else { return }
		isSuspendedForAccountChange = true
		if let debouncedMode {
			pendingWhileSuspended = debouncedMode
		}
		debouncedMode = nil
		debounce?.cancel()
		debounce = nil
		scheduler.cancel()
	}

	/// Drain work after `beginAccountChangeSuspension()` has closed the lane.
	public func drainForAccountChange() async {
		guard isSuspendedForAccountChange else { return }
		await scheduler.cancelAndDrain()
	}

	/// Convenience entry point for callers that only coordinate this store.
	public func suspendForAccountChange() async {
		beginAccountChangeSuspension()
		await drainForAccountChange()
	}

	/// Re-open the lane after account transition. A changed identity discards
	/// old dirty bookkeeping and replaces any suspended trigger with force-full.
	public func resumeAfterAccountChange(identityChanged: Bool) {
		guard isSuspendedForAccountChange else { return }
		isSuspendedForAccountChange = false
		let suspendedMode = pendingWhileSuspended
		pendingWhileSuspended = nil
		if identityChanged {
			scheduleSyncPass(mode: .forceFull)
		} else {
			scheduleSyncPass(mode: suspendedMode ?? .incremental)
		}
	}

	func waitUntilIdle() async {
		await scheduler.waitUntilIdle()
	}

	// MARK: - Core pass

	private func executeSyncPass(mode: SnippetSyncMode) async throws {
		do {
			// Step 1 — drain pending-delete outbox before fetch.
			let pendingDeletes = store.pendingDeletedSnippetIDs
			for id in pendingDeletes {
				try Task.checkCancellation()
				do {
					try await client.deleteSnippet(id: id)
					try Task.checkCancellation()
					try store.clearOutboxEntry(id)
				} catch {
					if error is CancellationError || Task.isCancelled {
						throw CancellationError()
					}
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
			try Task.checkCancellation()

			if batch.tokenExpired {
				Self.log.info("token expired — falling back to forceFull")
				let snapshot = try await client.fetchSnippetSnapshotAndCheckpoint()
				try Task.checkCancellation()
				try await applyBatch(snapshot)
				if let cp = snapshot.checkpoint {
					try Task.checkCancellation()
					try await client.commitSnippetCheckpoint(cp)
				}
				return
			}

			// Step 3 — apply then commit.
			try await applyBatch(batch)
			if let cp = batch.checkpoint {
				try Task.checkCancellation()
				try await client.commitSnippetCheckpoint(cp)
			}
		} catch {
			if error is CancellationError || Task.isCancelled {
				throw CancellationError()
			}
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

	private func applyBatch(_ batch: SnippetChangeBatch) async throws {
		let ops: [SnippetSyncOperation]
		switch batch.mode {
		case .forceFull:
			ops = SnippetSyncReconciler.reconcileFullSnapshot(
				local: store.snippets,
				remote: batch.changedSnippets,
				locallyDirty: store.locallyDirtySnippetIDs
			)
		case .incremental:
			ops = SnippetSyncReconciler.reconcileDelta(
				local: store.snippets,
				changedSnippets: batch.changedSnippets,
				deletedIDs: batch.deletedSnippetIDs,
				locallyDirty: store.locallyDirtySnippetIDs
			)
		}
		for op in ops {
			try Task.checkCancellation()
			switch op {
			case .applyRemote(let s):
				_ = try store.applyRemote(s)
			case .applyTombstone(let id):
				try store.applyRemoteTombstone(id: id)
			case .pushLocal(let s):
				do {
					let saved = try await client.pushSnippet(s)
					try Task.checkCancellation()
					do {
						// SnippetStore clears the durable dirty flag only when
						// this acknowledgement actually wins the merge. A newer
						// concurrent local edit therefore stays pending.
						_ = try store.applyRemote(saved)
					} catch {
						if error is CancellationError || Task.isCancelled {
							throw CancellationError()
						}
						Self.log.error("applyRemote after push failed for \(s.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
					}
				} catch {
					if error is CancellationError || Task.isCancelled {
						throw CancellationError()
					}
					Self.log.error("pushSnippet failed for \(s.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
					// Stay dirty; next pass retries.
				}
			}
		}
	}
}
