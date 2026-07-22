import Combine
import Foundation
import SnippetStore
import SnippetSyncClient

public enum MobileSnippetSyncState: Equatable, Sendable {
	case signedOut
	case syncing
	case upToDate(Date)
	case temporarilyUnavailable(String)
}

public enum MobileSnippetMutationError: LocalizedError, Equatable {
	case accountTransitionInProgress

	public var errorDescription: String? {
		"iCloud account is changing. Try again when synchronization is ready."
	}
}

/// iOS lifecycle owner for the shared Snippet store and sync scheduler.
/// Mutations always persist locally first; account or network failures leave
/// the durable dirty/outbox state for a later pass.
@MainActor
public final class MobileSnippetSyncRuntime: ObservableObject {
	@Published public private(set) var state: MobileSnippetSyncState = .signedOut

	public let store: SnippetStore
	public let sync: SnippetSyncStore
	private let client: any IncrementalSnippetSyncClient
	private let isSignedIn: () -> Bool
	private let refreshAccount: () async -> Void
	private var hasLaunched = false
	private var accountTransitionInProgress = false

	public init(
		store: SnippetStore,
		sync: SnippetSyncStore,
		client: any IncrementalSnippetSyncClient,
		isSignedIn: @escaping () -> Bool,
		refreshAccount: @escaping () async -> Void
	) {
		self.store = store
		self.sync = sync
		self.client = client
		self.isSignedIn = isSignedIn
		self.refreshAccount = refreshAccount
	}

	public func launch() async {
		guard !hasLaunched else { return }
		hasLaunched = true
		await refreshAccount()
		guard isSignedIn() else {
			state = .signedOut
			return
		}
		let mode = await client.preferredSnippetSyncMode()
		_ = await synchronize(mode: mode)
		sync.startForceFullTimer()
	}

	public func becameActive() async {
		guard hasLaunched else { return }
		await refreshAccount()
		guard isSignedIn() else {
			sync.stopForceFullTimer()
			state = .signedOut
			return
		}
		_ = await synchronize(mode: .incremental)
		sync.startForceFullTimer()
	}

	public func refresh() async {
		await refreshAccount()
		guard isSignedIn() else {
			sync.stopForceFullTimer()
			state = .signedOut
			return
		}
		_ = await synchronize(mode: .forceFull)
		sync.startForceFullTimer()
	}

	public func receivedCloudKitPush() async -> MobileHostSyncExecutionResult {
		guard !accountTransitionInProgress else { return .cancelled }
		await refreshAccount()
		guard isSignedIn() else {
			sync.stopForceFullTimer()
			state = .signedOut
			return .noData
		}
		let before = store.snippets
		let result = await synchronize(mode: .incremental)
		guard result == .noData else { return result }
		return before == store.snippets ? .noData : .newData
	}

	public func scheduleLocalMutation(debounceMs: Int = 500) {
		guard !accountTransitionInProgress else { return }
		guard isSignedIn() else {
			state = .signedOut
			return
		}
		sync.scheduleSyncPass(mode: .incremental, debounceMs: debounceMs)
	}

	public func upsert(_ snippet: Snippet) throws {
		try ensureMutationAllowed()
		try store.upsert(snippet)
		scheduleLocalMutation()
	}

	public func delete(id: UUID) throws {
		try ensureMutationAllowed()
		try store.delete(id: id)
		scheduleLocalMutation(debounceMs: 0)
	}

	public func move(fromOffsets: IndexSet, toOffset: Int) throws {
		try ensureMutationAllowed()
		try store.move(fromOffsets: fromOffsets, toOffset: toOffset)
	}

	public func replaceLocalSnapshot(_ snippets: [Snippet]) throws {
		try ensureMutationAllowed()
		try store.replaceLocalSnapshot(snippets)
		scheduleLocalMutation(debounceMs: 0)
	}

	public func beginAccountChangeSuspension() {
		guard !accountTransitionInProgress else { return }
		accountTransitionInProgress = true
		sync.stopForceFullTimer()
		sync.beginAccountChangeSuspension()
	}

	public func drainForAccountChange() async {
		guard accountTransitionInProgress else { return }
		await sync.drainForAccountChange()
	}

	public func resetLocalStateForAccountChange() throws {
		guard accountTransitionInProgress else {
			throw MobileSnippetMutationError.accountTransitionInProgress
		}
		try store.wipeLocal()
	}

	public func resumeAfterAccountChange(identityChanged: Bool) async {
		guard accountTransitionInProgress else { return }
		defer { accountTransitionInProgress = false }
		guard let mode = sync.resumeRequestAfterAccountChange(
			identityChanged: identityChanged
		) else { return }
		guard hasLaunched else { return }
		guard isSignedIn() else {
			state = .signedOut
			return
		}
		_ = await synchronize(mode: mode)
		sync.startForceFullTimer()
	}

	private func synchronize(
		mode: SnippetSyncMode
	) async -> MobileHostSyncExecutionResult {
		state = .syncing
		do {
			try await sync.runSyncPass(mode: mode)
			state = .upToDate(Date())
			return .noData
		} catch is CancellationError {
			return .cancelled
		} catch {
			state = .temporarilyUnavailable(error.localizedDescription)
			return .failed
		}
	}

	private func ensureMutationAllowed() throws {
		guard !accountTransitionInProgress else {
			throw MobileSnippetMutationError.accountTransitionInProgress
		}
	}
}
