import CredentialSyncStore
import CredentialSyncTypes
import Foundation

@MainActor
public final class CredentialSyncCoordinator {
    public enum CoordinatorError: Error {
        case iCloudKeychainUnavailable
        case accountChanged
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
        try await enable(transactionIsCurrent: { true })
    }

    public func enable(
        transactionIsCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        guard iCloudKeychainAvailable() else {
            throw CoordinatorError.iCloudKeychainUnavailable
        }
        guard transactionIsCurrent() else {
            throw CoordinatorError.accountChanged
        }
        var generatedKeyID: String?
        if await masterKeyStore.loadAny() == nil {
            let generated = try await masterKeyStore.generate()
            generatedKeyID = generated.keyID
        }
        guard transactionIsCurrent() else {
            if let generatedKeyID {
                await masterKeyStore.remove(keyID: generatedKeyID)
            }
            throw CoordinatorError.accountChanged
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
