import CredentialSyncStore
import Foundation
import SessionStore

/// Plan C / Task 20 — durable resumable destructive deletion flow.
///
/// `confirm` atomically clears every host's `credentialMaterialDirty` bit and
/// records a `DeletionProgress` entry naming every locally-known host with a
/// serverId. The matching driver lives in `HostSyncStore.runDestructiveSubPipeline`,
/// which pushes a `.tombstone` blob per host and shrinks the pending list as
/// each push succeeds. If the process is killed mid-pipeline, the persisted
/// list lets the next sync cycle resume from the remaining hosts.
@MainActor
public enum DestructiveDeletionFlow {
    /// Atomically:
    ///   1. Clear `credentialMaterialDirty` on every locally-known host so an
    ///      in-flight or post-kill cycle can't re-push the just-deleted blob.
    ///   2. Set `prefs.deleteCredentialsFromCloudInProgress` to a
    ///      `DeletionProgress` listing every host with a `serverId`. Hosts
    ///      that never reached the server are excluded — there's nothing to
    ///      tombstone for them.
    public static func confirm(
        sessionStore: SessionStore,
        credentialSync: CredentialSyncPreferencesStore,
        triggerSync: () -> Void = {}
    ) {
        let pendingIds = sessionStore.hosts.compactMap { host -> UUID? in
            host.serverId == nil ? nil : host.id
        }
        for host in sessionStore.hosts where host.credentialMaterialDirty {
            try? sessionStore.clearCredentialMaterialDirty(host.id)
        }
        credentialSync.mutate {
            $0.deleteCredentialsFromCloudInProgress = DeletionProgress(
                pendingLocalHostIds: pendingIds
            )
        }
        // Kick off the destructive sub-pipeline immediately. Without this
        // the tombstone push would only run on the next mutationsForSync
        // signal or 60-min force-full timer — leaving cloud populated for
        // an unbounded time after the user clicked "Delete".
        triggerSync()
    }
}
