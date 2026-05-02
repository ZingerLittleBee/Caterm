import CredentialSyncStore
import Foundation
import ManagedKeyStore

/// Wipes per-account credential-sync state when the iCloud account identity
/// changes. Called by CatermApp after AccountIdentityTracker reports
/// `.identityChanged`. The master key itself lives in iCloud Keychain and
/// travels with the user — we do NOT touch it; we only clear artifacts
/// (managed keys on disk, prefs/state) that were specific to the prior
/// identity.
@MainActor
public final class CredentialSyncAccountResetCoordinator {
	private let prefsStore: CredentialSyncPreferencesStore
	private let managedKeyStore: ManagedKeyStore

	public init(
		prefsStore: CredentialSyncPreferencesStore,
		managedKeyStore: ManagedKeyStore
	) {
		self.prefsStore = prefsStore
		self.managedKeyStore = managedKeyStore
	}

	public func resetForAccountChange() async {
		await managedKeyStore.wipeAll()
		prefsStore.mutate {
			$0.state = .disabled
			$0.lastAppliedRevision = [:]
			$0.credentialsNeedFullScan = false
			$0.deleteCredentialsFromCloudInProgress = nil
			$0.corruptCredentials = []
			$0.cloudCredentialsCleared = false
			$0.hostsWithCloudPayload = []
		}
	}
}
