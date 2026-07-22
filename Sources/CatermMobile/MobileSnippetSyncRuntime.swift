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
		await synchronize(mode: mode)
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
		await synchronize(mode: .incremental)
		sync.startForceFullTimer()
	}

	public func refresh() async {
		await refreshAccount()
		guard isSignedIn() else {
			sync.stopForceFullTimer()
			state = .signedOut
			return
		}
		await synchronize(mode: .forceFull)
		sync.startForceFullTimer()
	}

	public func receivedCloudKitPush() async -> MobileHostSyncExecutionResult {
		await refreshAccount()
		guard isSignedIn() else {
			sync.stopForceFullTimer()
			state = .signedOut
			return .noData
		}
		let before = store.snippets
		await synchronize(mode: .incremental)
		return before == store.snippets ? .noData : .newData
	}

	public func scheduleLocalMutation(debounceMs: Int = 500) {
		guard isSignedIn() else {
			state = .signedOut
			return
		}
		sync.scheduleSyncPass(mode: .incremental, debounceMs: debounceMs)
	}

	private func synchronize(mode: SnippetSyncMode) async {
		state = .syncing
		do {
			try await client.ensureSnippetSubscription()
			await sync.runSyncPass(mode: mode)
			state = .upToDate(Date())
		} catch is CancellationError {
			return
		} catch {
			state = .temporarilyUnavailable(error.localizedDescription)
		}
	}
}
