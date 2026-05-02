import CloudKit
import Foundation
import ServerSyncClient

/// Minimal `CKContainer` surface for testability.
public protocol CKAccountStatusProviding: Sendable {
    func accountStatus() async throws -> CKAccountStatus
}

extension CKContainer: CKAccountStatusProviding {}

/// `AuthSessionProtocol` impl backed by `CKContainer.accountStatus`.
///
/// Cached `isSignedIn` defaults to false. The caller is expected to call
/// `refresh()` after init (and on `.CKAccountChanged` notifications, see
/// `startObservingAccountChanges()` below).
///
/// Errors during `refresh()` are swallowed — they do NOT flip the cached
/// value. Reasoning: a transient `CKError.networkUnavailable` while the
/// user is actually signed in must not flip our cache to `false` and
/// suppress sync. Any real sign-out surfaces as `.noAccount` /
/// `.restricted`, which we DO honor.
@MainActor
public final class iCloudAccountSession: AuthSessionProtocol {
    private let provider: CKAccountStatusProviding
    public private(set) var isSignedIn: Bool = false

    /// Retained internally so the caller does not need to track it. When
    /// the session is deinit'd, this token's owning closure is released
    /// and the observer is removed by the GC of NotificationCenter.
    private var accountChangeObserver: NSObjectProtocol?

    public init(provider: CKAccountStatusProviding) {
        self.provider = provider
    }

    deinit {
        if let token = accountChangeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    public func refresh() async {
        do {
            let status = try await provider.accountStatus()
            isSignedIn = (status == .available)
        } catch {
            // intentionally no state change — see doc comment.
            return
        }
    }

    /// Idempotent: calling twice replaces the previous observer.
    public func startObservingAccountChanges() {
        if let prior = accountChangeObserver {
            NotificationCenter.default.removeObserver(prior)
        }
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
                // Notify HostSyncStore to re-attempt sync if the user
                // just signed in. Decoupled from any direct reference to
                // HostSyncStore to keep this module independent.
                NotificationCenter.default.post(
                    name: .catermICloudAccountChanged, object: nil
                )
            }
        }
    }
}

extension Notification.Name {
    /// Posted after `iCloudAccountSession.refresh()` runs in response to
    /// `CKAccountChanged`. `CatermApp` wires this to
    /// `HostSyncStore.syncIfSignedIn()` so an in-app sign-in to iCloud
    /// triggers an immediate sync.
    public static let catermICloudAccountChanged =
        Notification.Name("catermICloudAccountChanged")
}
