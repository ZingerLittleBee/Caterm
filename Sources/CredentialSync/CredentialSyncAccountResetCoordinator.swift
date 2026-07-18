import CredentialSyncStore
import Foundation
import SessionStore

/// Wipes per-account credential-sync state when the iCloud account identity
/// changes. Called by CatermApp after AccountIdentityTracker reports
/// `.identityChanged`. The master key itself lives in iCloud Keychain and
/// travels with the user — we do NOT touch it; we only clear artifacts
/// (managed keys on disk, prefs/state) that were specific to the prior
/// identity.
@MainActor
public final class CredentialSyncAccountResetCoordinator {
	private let prefsStore: CredentialSyncPreferencesStore
	private let sessionStore: SessionStore

	public init(
		prefsStore: CredentialSyncPreferencesStore,
		sessionStore: SessionStore
	) {
		self.prefsStore = prefsStore
		self.sessionStore = sessionStore
	}

	public func resetForAccountChange() async throws {
		// Disable sync before suspending so in-flight remote commits roll back
		// while the material barrier waits for their per-host leases.
		prefsStore.mutate {
			$0.state = .disabled
			$0.lastAppliedRevision = [:]
			$0.credentialsNeedFullScan = false
			$0.deleteCredentialsFromCloudInProgress = nil
			$0.corruptCredentials = []
			$0.cloudCredentialsCleared = false
			$0.hostsWithCloudPayload = []
		}
		try await sessionStore.resetCredentialMaterialForAccountChange()
	}
}
