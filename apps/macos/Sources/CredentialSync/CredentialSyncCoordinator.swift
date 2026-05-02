import CredentialSyncStore
import CredentialSyncTypes
import Foundation

@MainActor
public final class CredentialSyncCoordinator {
    public enum CoordinatorError: Error {
        case iCloudKeychainUnavailable
    }

    private let prefsStore: CredentialSyncPreferencesStore
    private let masterKeyStore: KeychainSyncMasterKeyStore
    private let iCloudKeychainAvailable: () -> Bool

    public init(
        prefsStore: CredentialSyncPreferencesStore,
        masterKeyStore: KeychainSyncMasterKeyStore,
        iCloudKeychainAvailable: @escaping () -> Bool = { true }
    ) {
        self.prefsStore = prefsStore
        self.masterKeyStore = masterKeyStore
        self.iCloudKeychainAvailable = iCloudKeychainAvailable
    }

    public func enable() async throws {
        guard iCloudKeychainAvailable() else {
            throw CoordinatorError.iCloudKeychainUnavailable
        }
        if await masterKeyStore.loadAny() == nil {
            _ = try await masterKeyStore.generate()
        }
        prefsStore.mutate {
            $0.state = .enabled
            $0.credentialsNeedFullScan = true
        }
    }

    public func disable() {
        prefsStore.mutate { $0.state = .disabled }
    }

    public func reconcileMasterKeyArrival() async {
        guard case .waitingForKey = prefsStore.prefs.state else { return }
        if await masterKeyStore.loadAny() != nil {
            prefsStore.mutate {
                $0.state = .enabled
                $0.credentialsNeedFullScan = true
            }
        }
    }
}
