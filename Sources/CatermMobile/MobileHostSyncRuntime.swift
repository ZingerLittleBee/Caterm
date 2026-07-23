import CloudKitSyncClient
import Combine
import CredentialSync
import CredentialSyncStore
import Foundation
import ServerSyncClient

public enum MobileHostSyncState: Equatable, Sendable {
	case checkingAccount
	case signedOut
	case syncing
	case upToDate(Date)
	case temporarilyUnavailable(String)
	case failed(String)
}

public enum MobileHostSyncExecutionResult: Equatable, Sendable {
	case noData
	case newData
	case failed
	case cancelled
}

public struct MobileAccountIdentityBoundary {
	let evaluate: () async -> AccountChangeOutcome
	let acknowledge: () async -> Void
	let beginRelatedSyncSuspension: @MainActor () -> Void
	let drainRelatedSync: @MainActor () async -> Void
	let resetRelatedLocalState: @MainActor () async throws -> Void
	let allowRelatedLocalMutationsWhileSuspended: @MainActor () -> Void
	let resumeRelatedSync: @MainActor (_ identityChanged: Bool) async -> Void

	public init(
		evaluate: @escaping () async -> AccountChangeOutcome,
		acknowledge: @escaping () async -> Void,
		beginRelatedSyncSuspension: @escaping @MainActor () -> Void = {},
		drainRelatedSync: @escaping @MainActor () async -> Void = {},
		resetRelatedLocalState:
			@escaping @MainActor () async throws -> Void = {},
		allowRelatedLocalMutationsWhileSuspended: @escaping @MainActor () -> Void = {},
		resumeRelatedSync: @escaping @MainActor (_ identityChanged: Bool) async -> Void = { _ in }
	) {
		self.evaluate = evaluate
		self.acknowledge = acknowledge
		self.beginRelatedSyncSuspension = beginRelatedSyncSuspension
		self.drainRelatedSync = drainRelatedSync
		self.resetRelatedLocalState = resetRelatedLocalState
		self.allowRelatedLocalMutationsWhileSuspended =
			allowRelatedLocalMutationsWhileSuspended
		self.resumeRelatedSync = resumeRelatedSync
	}
}

/// Native iOS lifecycle adapter around the platform-neutral synchronization
/// engine. Cached Hosts remain owned by `MobileHostStore` and visible while
/// this runtime checks account state or waits for connectivity.
@MainActor
public final class MobileHostSyncRuntime: ObservableObject {
	@Published public private(set) var state: MobileHostSyncState = .checkingAccount
	@Published public private(set) var identityRevision: UInt64 = 0

	public let hostStore: MobileHostStore
	private let syncEngine: SharedHostSyncEngine
	private let client: any IncrementalHostSyncClient
	private let credentialSync: CredentialSyncPreferencesStore
	private let isSignedIn: () -> Bool
	private let refreshAccount: () async -> Void
	private let identityBoundary: MobileAccountIdentityBoundary?
	private let debounceNanoseconds: UInt64
	private var cancellables: Set<AnyCancellable> = []
	private var activeTask: Task<MobileHostSyncExecutionResult, Never>?
	private var activeRunID: UUID?
	private var activeRequest: SharedHostSyncRequest?
	private var pendingHostRequest: SharedHostSyncRequest?
	private var debounceTask: Task<Void, Never>?
	private var lifecycleGeneration: UInt64 = 0
	private var accountTransitionInProgress = false
	private var remoteSyncSuspendedForAccountCheck = false
	private var hasLaunched = false

	public init(
		hostStore: MobileHostStore,
		syncEngine: SharedHostSyncEngine,
		client: any IncrementalHostSyncClient,
		credentialSync: CredentialSyncPreferencesStore,
		isSignedIn: @escaping () -> Bool,
		refreshAccount: @escaping () async -> Void,
		identityBoundary: MobileAccountIdentityBoundary? = nil,
		debounceInterval: TimeInterval = 1.5
	) {
		self.hostStore = hostStore
		self.syncEngine = syncEngine
		self.client = client
		self.credentialSync = credentialSync
		self.isSignedIn = isSignedIn
		self.refreshAccount = refreshAccount
		self.identityBoundary = identityBoundary
		self.debounceNanoseconds = UInt64(
			max(0, debounceInterval) * 1_000_000_000
		)

		hostStore.localMutations
			.sink { [weak self] in self?.scheduleMutationSync() }
			.store(in: &cancellables)

		NotificationCenter.default.publisher(for: .catermCloudKitHostChanged)
			.sink { [weak self] _ in self?.scheduleSync(request: .incremental) }
			.store(in: &cancellables)
	}

	deinit {
		activeTask?.cancel()
		debounceTask?.cancel()
	}

	public func launch() async {
		guard !hasLaunched else { return }
		hasLaunched = true
		_ = await replaceActiveRun(checkIdentity: true, request: .automatic)
	}

	public func becameActive() async {
		guard hasLaunched else { return }
		_ = await replaceActiveRun(checkIdentity: true, request: .automatic)
	}

	public func receivedCloudKitPush() async -> MobileHostSyncExecutionResult {
		await replaceActiveRun(checkIdentity: true, request: .incremental)
	}

	public func prepareForRelatedSync() async -> MobileHostSyncExecutionResult {
		pendingHostRequest = mergedRequest(pendingHostRequest, activeRequest)
		if debounceTask != nil {
			pendingHostRequest = mergedRequest(pendingHostRequest, .automatic)
		}
		let result = await replaceActiveRun(checkIdentity: true, request: nil)
		guard result != .failed, result != .cancelled, isSignedIn(),
			let pendingHostRequest else { return result }
		self.pendingHostRequest = nil
		scheduleSync(request: pendingHostRequest)
		return result
	}

	public func refresh() async {
		_ = await replaceActiveRun(checkIdentity: true, request: .forceFull)
	}

	@discardableResult
	public func accountDidChange() async -> MobileHostSyncExecutionResult {
		await replaceActiveRun(checkIdentity: true, request: .forceFull)
	}

	private func replaceActiveRun(
		checkIdentity: Bool,
		request: SharedHostSyncRequest?
	) async -> MobileHostSyncExecutionResult {
		if !checkIdentity,
			accountTransitionInProgress || remoteSyncSuspendedForAccountCheck {
			pendingHostRequest = mergedRequest(pendingHostRequest, request)
			return .cancelled
		}
		var resolvedRequest = request
		if request != nil, let pendingHostRequest {
			resolvedRequest = mergedRequest(request, pendingHostRequest)
			self.pendingHostRequest = nil
		}
		accountTransitionInProgress = true
		lifecycleGeneration &+= 1
		let generation = lifecycleGeneration
		debounceTask?.cancel()
		debounceTask = nil

		let prior = activeTask
		activeTask = nil
		activeRunID = nil
		activeRequest = nil
		prior?.cancel()
		_ = await prior?.result
		guard generationIsCurrent(generation) else { return .cancelled }

		let runID = UUID()
		let task = Task { @MainActor [weak self] in
			guard let self else { return MobileHostSyncExecutionResult.cancelled }
			return await refreshAndSynchronize(
				checkIdentity: checkIdentity,
				request: resolvedRequest,
				generation: generation
			)
		}
		activeRunID = runID
		activeRequest = resolvedRequest
		activeTask = task
		let result = await task.value
		if result == .failed, let resolvedRequest {
			pendingHostRequest = mergedRequest(
				pendingHostRequest,
				resolvedRequest
			)
		}
		if activeRunID == runID {
			activeTask = nil
			activeRunID = nil
			activeRequest = nil
		}
		return result
	}

	private func refreshAndSynchronize(
		checkIdentity: Bool,
		request: SharedHostSyncRequest?,
		generation: UInt64
	) async -> MobileHostSyncExecutionResult {
		if request != nil { state = .checkingAccount }
		await refreshAccount()
		guard generationIsCurrent(generation) else { return .cancelled }

		var resolvedRequest = request
		if checkIdentity, let identityBoundary {
			identityBoundary.beginRelatedSyncSuspension()
			await identityBoundary.drainRelatedSync()
			var relatedIdentityChanged = false
			let outcome = await identityBoundary.evaluate()
			guard generationIsCurrent(generation) else { return .cancelled }
			switch outcome {
			case .unchanged:
				break
			case .firstObservation:
				if resolvedRequest != nil { resolvedRequest = .forceFull }
			case .identityChanged:
				do {
					try await hostStore.resetForAccountChange()
					guard generationIsCurrent(generation) else { return .cancelled }
					resetCredentialSyncPreferences()
					try await identityBoundary.resetRelatedLocalState()
					relatedIdentityChanged = true
					await identityBoundary.acknowledge()
					try hostStore.finishAccountTransition()
					identityRevision &+= 1
					guard generationIsCurrent(generation) else { return .cancelled }
					if resolvedRequest != nil { resolvedRequest = .forceFull }
				} catch {
					guard generationIsCurrent(generation) else { return .cancelled }
					state = .temporarilyUnavailable(error.localizedDescription)
					remoteSyncSuspendedForAccountCheck = true
					accountTransitionInProgress = false
					return .failed
				}
			case .temporarilyUnavailable(let message):
				state = .temporarilyUnavailable(message)
				remoteSyncSuspendedForAccountCheck = true
				identityBoundary.allowRelatedLocalMutationsWhileSuspended()
				accountTransitionInProgress = false
				return .failed
			}
			remoteSyncSuspendedForAccountCheck = false
			await identityBoundary.resumeRelatedSync(relatedIdentityChanged)
			guard generationIsCurrent(generation) else { return .cancelled }
		}

		accountTransitionInProgress = false
		guard isSignedIn() else {
			state = .signedOut
			return .noData
		}
		guard let resolvedRequest else { return .noData }
		do {
			try await client.ensureHostSubscription()
			guard generationIsCurrent(generation) else { return .cancelled }
		} catch is CancellationError {
			return .cancelled
		} catch {
			guard generationIsCurrent(generation) else { return .cancelled }
			state = .failed(error.localizedDescription)
			return .failed
		}
		return await runSync(request: resolvedRequest, generation: generation)
	}

	private func resetCredentialSyncPreferences() {
		credentialSync.mutate {
			$0.state = .enabled
			$0.lastAppliedRevision = [:]
			$0.credentialsNeedFullScan = true
			$0.deleteCredentialsFromCloudInProgress = nil
			$0.corruptCredentials = []
			$0.cloudCredentialsCleared = false
			$0.hostsWithCloudPayload = []
			$0.decryptAttemptCounts = [:]
		}
	}

	private func scheduleMutationSync() {
		debounceTask?.cancel()
		if accountTransitionInProgress || remoteSyncSuspendedForAccountCheck {
			debounceTask = nil
			pendingHostRequest = mergedRequest(pendingHostRequest, .automatic)
			return
		}
		let generation = lifecycleGeneration
		debounceTask = Task { @MainActor [weak self] in
			guard let self else { return }
			do {
				try await Task.sleep(nanoseconds: debounceNanoseconds)
			} catch {
				return
			}
			guard generation == lifecycleGeneration else { return }
			scheduleSync(request: .automatic)
		}
	}

	private func scheduleSync(request: SharedHostSyncRequest) {
		guard isSignedIn() else { return }
		guard !accountTransitionInProgress,
			!remoteSyncSuspendedForAccountCheck else {
			pendingHostRequest = mergedRequest(pendingHostRequest, request)
			return
		}
		Task { @MainActor [weak self] in
			guard let self else { return }
			_ = await replaceActiveRun(checkIdentity: false, request: request)
		}
	}

	private func runSync(
		request: SharedHostSyncRequest,
		generation: UInt64
	) async -> MobileHostSyncExecutionResult {
		guard generationIsCurrent(generation),
			!accountTransitionInProgress,
			!remoteSyncSuspendedForAccountCheck,
			isSignedIn() else { return .cancelled }
		state = .syncing
		do {
			let result = try await syncEngine.synchronize(request: request)
			try Task.checkCancellation()
			guard generationIsCurrent(generation) else { return .cancelled }
			switch result {
			case .synchronized(_, let operations):
				state = .upToDate(Date())
				return operations.isEmpty ? .noData : .newData
			case .handledDestructiveCredentialDeletion:
				state = .upToDate(Date())
				return .newData
			}
		} catch is CancellationError {
			return .cancelled
		} catch {
			guard generationIsCurrent(generation) else { return .cancelled }
			state = .failed(error.localizedDescription)
			return .failed
		}
	}

	private func generationIsCurrent(_ generation: UInt64) -> Bool {
		generation == lifecycleGeneration && !Task.isCancelled
	}

	private func mergedRequest(
		_ current: SharedHostSyncRequest?,
		_ incoming: SharedHostSyncRequest?
	) -> SharedHostSyncRequest? {
		guard let incoming else { return current }
		guard let current else { return incoming }
		if current == .forceFull || incoming == .forceFull { return .forceFull }
		if current == .automatic || incoming == .automatic { return .automatic }
		return .incremental
	}
}
