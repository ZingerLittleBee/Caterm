import Foundation
import SettingsStore

/// Minimal surface of CloudKit's iCloudAccountSession we depend on, so this
/// module doesn't link CloudKit directly — the concrete iCloudAccountSession
/// from CloudKitSyncClient implements this implicitly.
public protocol AccountSessionProviding: AnyObject {
	var isSignedIn: Bool { get }
	func refresh() async
}

public extension Notification.Name {
	static let catermICloudAccountChanged =
		Notification.Name("catermICloudAccountChanged")
}

@MainActor
public final class SettingsSyncStore {
	public static let kvsKey = "caterm.settings.v1"

	private let store: SettingsStore
	private let kvs: KVSProtocol
	private let accountSession: AccountSessionProviding
	private let tokenStore: IdentityTokenStore
	private let currentTokenProvider: () -> (NSObject & NSCoding & NSCopying)?

	// Lifecycle observer (app-lifetime)
	private var accountChangeObserver: NSObjectProtocol?

	// Sync observers (registered by startSync, removed by stopSync)
	private var kvsExternalObserver: NSObjectProtocol?
	private var settingsChangeObserver: NSObjectProtocol?

	public var pushSuspended: Bool = true   // initial barrier — cleared by startSync's decision pass
	private var isSyncRunning: Bool = false

	// Test counters
	public private(set) var startSyncCallCount = 0
	public private(set) var observersRegisteredCount = 0

	public init(
		store: SettingsStore,
		kvs: KVSProtocol,
		accountSession: AccountSessionProviding,
		tokenStore: IdentityTokenStore,
		currentTokenProvider: @escaping () -> (NSObject & NSCoding & NSCopying)?
	) {
		self.store = store
		self.kvs = kvs
		self.accountSession = accountSession
		self.tokenStore = tokenStore
		self.currentTokenProvider = currentTokenProvider
	}

	/// App-lifetime observer for sign-in transitions. Called once at app
	/// startup; the observer is NEVER removed for the life of the process.
	public func installLifecycleObservers() {
		guard accountChangeObserver == nil else { return }
		accountChangeObserver = NotificationCenter.default.addObserver(
			forName: .catermICloudAccountChanged, object: nil, queue: .main
		) { [weak self] _ in
			Task { @MainActor [weak self] in
				guard let self = self else { return }
				if self.accountSession.isSignedIn && !self.isSyncRunning {
					await self.startSync()
				} else if !self.accountSession.isSignedIn && self.isSyncRunning {
					self.stopSync()
				}
			}
		}
	}

	public func startSync() async {
		startSyncCallCount += 1
		if isSyncRunning { return }
		guard accountSession.isSignedIn else { return }
		isSyncRunning = true
		observersRegisteredCount += 1
		// Sync observers wired in Task 13–18.
	}

	public func stopSync() {
		guard isSyncRunning else { return }
		isSyncRunning = false
		if let token = kvsExternalObserver {
			NotificationCenter.default.removeObserver(token)
			kvsExternalObserver = nil
		}
		if let token = settingsChangeObserver {
			NotificationCenter.default.removeObserver(token)
			settingsChangeObserver = nil
		}
		pushSuspended = true
	}
}

public enum TokenClassification: Equatable {
	case notSignedIn
	case firstObservation     // prev nil, curr non-nil — no prior identity to leak
	case identitySame         // prev and curr both non-nil and isEqual
	case identityChanged      // prev and curr both non-nil and NOT isEqual
	case signedOut            // prev non-nil, curr nil
	case unknownPrevious      // sentinel "<archive-failed>" — route conservatively
}

public enum TokenClassifier {
	public static func classify(
		persisted: PersistedTokenLoad,
		current: (NSObject & NSCoding & NSCopying)?
	) -> TokenClassification {
		if case .archiveFailed = persisted { return .unknownPrevious }
		switch (persisted, current) {
		case (.none, nil): return .notSignedIn
		case (.none, _?): return .firstObservation
		case (.token, nil): return .signedOut
		case (.token(let prev), let curr?):
			return prev.isEqual(curr) ? .identitySame : .identityChanged
		default: return .notSignedIn   // unreachable; .archiveFailed handled above
		}
	}
}
