import Combine
import Foundation
import SettingsSyncStore

@MainActor
public protocol MobileSettingsSyncing: AnyObject {
	var executionResultPublisher: AnyPublisher<SettingsSyncExecutionResult, Never> { get }
	func startSyncAndReport() async -> SettingsSyncExecutionResult
	func synchronizeNow() async -> SettingsSyncExecutionResult
	func stopSync()
}

extension SettingsSyncStore: MobileSettingsSyncing {}

public enum MobileSyncStatus: Equatable, Sendable {
	case checkingAccount
	case signedOut
	case syncing
	case upToDate(lastSuccessfulAt: Date)
	case temporarilyUnavailable(String)
	case failed(String)

	public var accessibilityDescription: String {
		switch self {
		case .checkingAccount:
			"Checking iCloud account"
		case .signedOut:
			"iCloud sync is signed out. Local data remains available."
		case .syncing:
			"Syncing iCloud data"
		case .upToDate(let date):
			"iCloud data is up to date. Last synced \(date.formatted())."
		case .temporarilyUnavailable(let message):
			"iCloud is temporarily unavailable. \(message)"
		case .failed(let message):
			"iCloud sync failed. \(message)"
		}
	}
}

enum MobileSimulatorSyncScenario: String {
	case signedOut = "signed-out"
	case failed
	case temporarilyUnavailable = "temporarily-unavailable"

	static var current: Self? {
		#if targetEnvironment(simulator)
		guard let rawValue = ProcessInfo.processInfo.environment[
			"CATERM_SIM_SYNC_STATUS"
		] else { return nil }
		return Self(rawValue: rawValue)
		#else
		return nil
		#endif
	}

	var status: MobileSyncStatus {
		switch self {
		case .signedOut:
			.signedOut
		case .failed:
			.failed("The network connection appears to be offline.")
		case .temporarilyUnavailable:
			.temporarilyUnavailable(
				"iCloud account status is temporarily unavailable."
			)
		}
	}
}

/// Serializes every native iOS lifecycle input through one sync boundary.
/// The platform runtimes retain ownership of Host/Snippet account safety;
/// this coordinator owns ordering, aggregate status, and recovery actions.
@MainActor
public final class MobileSyncCoordinator: ObservableObject {
	@Published public private(set) var status: MobileSyncStatus = .checkingAccount
	public let isAvailable: Bool

	private enum Trigger {
		case launch
		case becameActive
		case pullToRefresh
		case syncNow
		case accountChanged
		case hostPush
		case snippetPush
	}

	private let hostRuntime: MobileHostSyncRuntime
	private let snippetRuntime: MobileSnippetSyncRuntime
	private let settingsSync: (any MobileSettingsSyncing)?
	private let startObservingAccountChanges: () -> Void
	private var activeTask: Task<MobileHostSyncExecutionResult, Never>?
	private var activeRunID: UUID?
	private var hasLaunched = false
	private var cancellables: Set<AnyCancellable> = []
	private var simulatorStatusOverride: MobileSyncStatus?
	private var settingsResult: SettingsSyncExecutionResult?

	public init(
		hostRuntime: MobileHostSyncRuntime,
		snippetRuntime: MobileSnippetSyncRuntime,
		settingsSync: (any MobileSettingsSyncing)?,
		isAvailable: Bool = true,
		startObservingAccountChanges: @escaping () -> Void = {}
	) {
		self.hostRuntime = hostRuntime
		self.snippetRuntime = snippetRuntime
		self.settingsSync = settingsSync
		self.isAvailable = isAvailable
		self.startObservingAccountChanges = startObservingAccountChanges
		self.simulatorStatusOverride = Self.makeSimulatorStatusOverride()

		hostRuntime.$state
			.combineLatest(snippetRuntime.$state)
			.sink { [weak self] host, snippet in
				guard let self, self.activeTask == nil else { return }
				self.projectStatus(host: host, snippet: snippet)
			}
			.store(in: &cancellables)

		settingsSync?.executionResultPublisher
			.sink { [weak self] result in
				guard let self else { return }
				self.settingsResult = result
				guard self.activeTask == nil else { return }
				self.projectStatus(
					host: self.hostRuntime.state,
					snippet: self.snippetRuntime.state
				)
			}
			.store(in: &cancellables)
	}

	deinit { activeTask?.cancel() }

	public func launch() async {
		guard !hasLaunched else { return }
		hasLaunched = true
		startObservingAccountChanges()
		_ = await submit(.launch)
	}

	public func becameActive() async {
		guard hasLaunched else { return }
		_ = await submit(.becameActive)
	}

	public func pullToRefresh() async {
		simulatorStatusOverride = nil
		_ = await submit(.pullToRefresh)
	}

	public func syncNow() async {
		simulatorStatusOverride = nil
		_ = await submit(.syncNow)
	}

	public func accountChanged() async {
		_ = await submit(.accountChanged)
	}

	public func receivedHostPush() async -> MobileHostSyncExecutionResult {
		await submit(.hostPush)
	}

	public func receivedSnippetPush() async -> MobileHostSyncExecutionResult {
		await submit(.snippetPush)
	}

	private func submit(_ trigger: Trigger) async -> MobileHostSyncExecutionResult {
		let predecessor = activeTask
		status = .syncing
		let runID = UUID()
		let task = Task { @MainActor [weak self] in
			_ = await predecessor?.value
			guard let self else { return MobileHostSyncExecutionResult.cancelled }
			return await execute(trigger)
		}
		activeRunID = runID
		activeTask = task
		let result = await task.value
		if activeRunID == runID {
			activeTask = nil
			activeRunID = nil
			projectStatus(host: hostRuntime.state, snippet: snippetRuntime.state)
		}
		return result
	}

	private func execute(_ trigger: Trigger) async -> MobileHostSyncExecutionResult {
		settingsSync?.stopSync()
		let hostResult: MobileHostSyncExecutionResult
		let snippetResult: MobileHostSyncExecutionResult
		switch trigger {
		case .launch:
			await hostRuntime.launch()
			hostResult = result(for: hostRuntime.state)
			if suspendSettingsIfAccountUnavailable() { return hostResult }
			await snippetRuntime.launch()
			snippetResult = result(for: snippetRuntime.state)
			await synchronizeSettings(startIfNeeded: true)
		case .becameActive:
			await hostRuntime.becameActive()
			hostResult = result(for: hostRuntime.state)
			if suspendSettingsIfAccountUnavailable() { return hostResult }
			await snippetRuntime.becameActive()
			snippetResult = result(for: snippetRuntime.state)
			await synchronizeSettings(startIfNeeded: true)
		case .pullToRefresh, .syncNow:
			await hostRuntime.refresh()
			hostResult = result(for: hostRuntime.state)
			if suspendSettingsIfAccountUnavailable() { return hostResult }
			await snippetRuntime.refresh()
			snippetResult = result(for: snippetRuntime.state)
			await synchronizeSettings(startIfNeeded: false)
		case .accountChanged:
			hostResult = await hostRuntime.accountDidChange()
			if suspendSettingsIfAccountUnavailable() { return hostResult }
			guard hostResult != .cancelled else { return hostResult }
			await snippetRuntime.refresh()
			snippetResult = result(for: snippetRuntime.state)
			await synchronizeSettings(startIfNeeded: false)
		case .hostPush:
			hostResult = await hostRuntime.receivedCloudKitPush()
			if suspendSettingsIfAccountUnavailable() { return hostResult }
			snippetResult = .noData
			await synchronizeSettings(startIfNeeded: true)
		case .snippetPush:
			hostResult = await hostRuntime.prepareForRelatedSync()
			if suspendSettingsIfAccountUnavailable() { return hostResult }
			guard hostResult != .failed, hostResult != .cancelled else {
				return hostResult
			}
			snippetResult = await snippetRuntime.receivedCloudKitPushAfterIdentityCheck()
			await synchronizeSettings(startIfNeeded: true)
		}
		return combined(hostResult, snippetResult, settingsResult)
	}

	private func suspendSettingsIfAccountUnavailable() -> Bool {
		switch hostRuntime.state {
		case .temporarilyUnavailable(let message):
			settingsResult = .failed(message)
			return true
		case .signedOut:
			settingsResult = .signedOut
			return false
		case .checkingAccount, .syncing, .upToDate, .failed:
			return false
		}
	}

	private func synchronizeSettings(startIfNeeded: Bool) async {
		guard let settingsSync else { return }
		settingsResult = if startIfNeeded {
			await settingsSync.startSyncAndReport()
		} else {
			await settingsSync.synchronizeNow()
		}
	}

	private func combined(
		_ host: MobileHostSyncExecutionResult,
		_ snippet: MobileHostSyncExecutionResult,
		_ settings: SettingsSyncExecutionResult?
	) -> MobileHostSyncExecutionResult {
		if case .some(.failed) = settings { return .failed }
		if host == .failed || snippet == .failed { return .failed }
		if host == .cancelled || snippet == .cancelled { return .cancelled }
		if host == .newData || snippet == .newData { return .newData }
		return .noData
	}

	private func result(for state: MobileHostSyncState) -> MobileHostSyncExecutionResult {
		switch state {
		case .temporarilyUnavailable, .failed: .failed
		case .checkingAccount, .syncing: .cancelled
		case .signedOut, .upToDate: .noData
		}
	}

	private func result(for state: MobileSnippetSyncState) -> MobileHostSyncExecutionResult {
		switch state {
		case .temporarilyUnavailable, .failed: .failed
		case .syncing: .cancelled
		case .signedOut, .upToDate: .noData
		}
	}

	private func projectStatus(
		host: MobileHostSyncState,
		snippet: MobileSnippetSyncState
	) {
		if let simulatorStatusOverride {
			status = simulatorStatusOverride
			return
		}
		if case .failed(let message) = host {
			status = .failed(message)
			return
		}
		if case .failed(let message) = snippet {
			status = .failed(message)
			return
		}
		if case .temporarilyUnavailable(let message) = host {
			status = .temporarilyUnavailable(message)
			return
		}
		if case .temporarilyUnavailable(let message) = snippet {
			status = .temporarilyUnavailable(message)
			return
		}
		if case .failed(let message) = settingsResult {
			status = .failed(message)
			return
		}
		if case .checkingAccount = host {
			status = .checkingAccount
			return
		}
		if case .syncing = host {
			status = .syncing
			return
		}
		if case .syncing = snippet {
			status = .syncing
			return
		}
		if case .signedOut = host {
			status = .signedOut
			return
		}
		if case .signedOut = snippet {
			status = .signedOut
			return
		}
		if case .signedOut = settingsResult {
			status = .signedOut
			return
		}
		guard case .upToDate(let hostDate) = host,
			case .upToDate(let snippetDate) = snippet else { return }
		let lastSuccessfulAt: Date
		if case .upToDate(let settingsDate) = settingsResult {
			lastSuccessfulAt = max(max(hostDate, snippetDate), settingsDate)
		} else {
			lastSuccessfulAt = max(hostDate, snippetDate)
		}
		status = .upToDate(lastSuccessfulAt: lastSuccessfulAt)
	}

	private static func makeSimulatorStatusOverride() -> MobileSyncStatus? {
		MobileSimulatorSyncScenario.current?.status
	}
}
