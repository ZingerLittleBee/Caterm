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

	public var accessibilityDescription: String {
		switch self {
		case .checkingAccount:
			"Checking iCloud account"
		case .signedOut:
			"iCloud sync is signed out"
		case .syncing:
			"Syncing Hosts"
		case .upToDate:
			"Hosts are up to date"
		case .temporarilyUnavailable:
			"Host sync is temporarily unavailable"
		}
	}
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

	public init(
		evaluate: @escaping () async -> AccountChangeOutcome,
		acknowledge: @escaping () async -> Void
	) {
		self.evaluate = evaluate
		self.acknowledge = acknowledge
	}
}

/// Native iOS lifecycle adapter around the platform-neutral synchronization
/// engine. Cached Hosts remain owned by `MobileHostStore` and visible while
/// this runtime checks account state or waits for connectivity.
@MainActor
public final class MobileHostSyncRuntime: ObservableObject {
	@Published public private(set) var state: MobileHostSyncState = .checkingAccount

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
	private var debounceTask: Task<Void, Never>?
	private var lifecycleGeneration: UInt64 = 0
	private var accountTransitionInProgress = false
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

	public func refresh() async {
		_ = await replaceActiveRun(checkIdentity: true, request: .forceFull)
	}

	public func accountDidChange() async {
		_ = await replaceActiveRun(checkIdentity: true, request: .forceFull)
	}

	private func replaceActiveRun(
		checkIdentity: Bool,
		request: SharedHostSyncRequest
	) async -> MobileHostSyncExecutionResult {
		accountTransitionInProgress = true
		lifecycleGeneration &+= 1
		let generation = lifecycleGeneration
		debounceTask?.cancel()
		debounceTask = nil

		let prior = activeTask
		activeTask = nil
		activeRunID = nil
		prior?.cancel()
		_ = await prior?.result
		guard generationIsCurrent(generation) else { return .cancelled }

		let runID = UUID()
		let task = Task { @MainActor [weak self] in
			guard let self else { return MobileHostSyncExecutionResult.cancelled }
			return await refreshAndSynchronize(
				checkIdentity: checkIdentity,
				request: request,
				generation: generation
			)
		}
		activeRunID = runID
		activeTask = task
		let result = await task.value
		if activeRunID == runID {
			activeTask = nil
			activeRunID = nil
		}
		return result
	}

	private func refreshAndSynchronize(
		checkIdentity: Bool,
		request: SharedHostSyncRequest,
		generation: UInt64
	) async -> MobileHostSyncExecutionResult {
		state = .checkingAccount
		await refreshAccount()
		guard generationIsCurrent(generation) else { return .cancelled }

		var resolvedRequest = request
		if checkIdentity, let identityBoundary {
			let outcome = await identityBoundary.evaluate()
			guard generationIsCurrent(generation) else { return .cancelled }
			switch outcome {
			case .unchanged:
				break
			case .firstObservation:
				resolvedRequest = .forceFull
			case .identityChanged:
				do {
					try await hostStore.resetForAccountChange()
					guard generationIsCurrent(generation) else { return .cancelled }
					resetCredentialSyncPreferences()
					await identityBoundary.acknowledge()
					try hostStore.finishAccountTransition()
					guard generationIsCurrent(generation) else { return .cancelled }
					resolvedRequest = .forceFull
				} catch {
					guard generationIsCurrent(generation) else { return .cancelled }
					state = .temporarilyUnavailable(error.localizedDescription)
					accountTransitionInProgress = false
					return .failed
				}
			case .temporarilyUnavailable(let message):
				state = .temporarilyUnavailable(message)
				accountTransitionInProgress = false
				return .failed
			}
		}

		accountTransitionInProgress = false
		guard isSignedIn() else {
			state = .signedOut
			return .noData
		}
		do {
			try await client.ensureHostSubscription()
			guard generationIsCurrent(generation) else { return .cancelled }
		} catch is CancellationError {
			return .cancelled
		} catch {
			guard generationIsCurrent(generation) else { return .cancelled }
			state = .temporarilyUnavailable(error.localizedDescription)
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
		guard !accountTransitionInProgress, isSignedIn() else { return }
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
			state = .temporarilyUnavailable(error.localizedDescription)
			return .failed
		}
	}

	private func generationIsCurrent(_ generation: UInt64) -> Bool {
		generation == lifecycleGeneration && !Task.isCancelled
	}
}
