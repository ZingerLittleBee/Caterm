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
	private var activeTask: Task<Void, Never>?
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
		await refreshAndSynchronize(checkIdentity: true, request: .automatic)
	}

	public func becameActive() async {
		guard hasLaunched else { return }
		await refreshAndSynchronize(checkIdentity: true, request: .automatic)
	}

	public func receivedCloudKitPush() {
		scheduleSync(request: .incremental)
	}

	public func refresh() async {
		await refreshAndSynchronize(checkIdentity: true, request: .forceFull)
	}

	public func accountDidChange() async {
		await refreshAndSynchronize(checkIdentity: true, request: .forceFull)
	}

	private func refreshAndSynchronize(
		checkIdentity: Bool,
		request: SharedHostSyncRequest
	) async {
		await suspendCurrentWorkForAccountBoundary()
		state = .checkingAccount
		await refreshAccount()

		var resolvedRequest = request
		if checkIdentity, let identityBoundary {
			let outcome = await identityBoundary.evaluate()
			switch outcome {
			case .unchanged:
				break
			case .firstObservation:
				resolvedRequest = .forceFull
			case .identityChanged:
				do {
					try await hostStore.resetForAccountChange()
					resetCredentialSyncPreferences()
					await identityBoundary.acknowledge()
					resolvedRequest = .forceFull
				} catch {
					state = .temporarilyUnavailable(error.localizedDescription)
					accountTransitionInProgress = false
					return
				}
			}
		}

		accountTransitionInProgress = false
		guard isSignedIn() else {
			state = .signedOut
			return
		}
		try? await client.ensureHostSubscription()
		await runSync(request: resolvedRequest)
	}

	private func suspendCurrentWorkForAccountBoundary() async {
		accountTransitionInProgress = true
		lifecycleGeneration &+= 1
		debounceTask?.cancel()
		debounceTask = nil
		let prior = activeTask
		activeTask = nil
		prior?.cancel()
		_ = await prior?.result
	}

	private func resetCredentialSyncPreferences() {
		credentialSync.mutate {
			$0.state = .disabled
			$0.lastAppliedRevision = [:]
			$0.credentialsNeedFullScan = false
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
		let generation = lifecycleGeneration
		activeTask?.cancel()
		activeTask = Task { @MainActor [weak self] in
			guard let self else { return }
			await runSync(request: request, generation: generation)
		}
	}

	private func runSync(
		request: SharedHostSyncRequest,
		generation: UInt64? = nil
	) async {
		let expectedGeneration = generation ?? lifecycleGeneration
		guard expectedGeneration == lifecycleGeneration,
			!accountTransitionInProgress,
			isSignedIn() else { return }
		state = .syncing
		do {
			let result = try await syncEngine.synchronize(request: request)
			try Task.checkCancellation()
			guard expectedGeneration == lifecycleGeneration else { return }
			if case .synchronized = result {
				state = .upToDate(Date())
			}
		} catch is CancellationError {
			return
		} catch {
			guard expectedGeneration == lifecycleGeneration else { return }
			state = .temporarilyUnavailable(error.localizedDescription)
		}
	}
}
