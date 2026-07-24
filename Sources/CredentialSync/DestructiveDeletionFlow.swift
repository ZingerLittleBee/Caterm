import CredentialSyncStore
import Foundation
import os
import SessionStore

/// Plan C / Task 20 — durable resumable destructive deletion flow.
///
/// `confirm` atomically clears every host's `credentialMaterialDirty` bit and
/// records a `DeletionProgress` entry naming every locally-known host with a
/// serverId. The matching driver lives in `HostSyncStore.runDestructiveSubPipeline`,
/// which pushes a `.tombstone` blob per host and shrinks the pending list as
/// each push succeeds. `HostCredentialSyncEngine` drives that pipeline before
/// normal host sync. If the process is killed mid-pipeline, the persisted list
/// lets the next sync cycle resume from the remaining hosts.
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
    ) async {
        let pendingIds = sessionStore.hosts.compactMap { host -> UUID? in
            host.serverId == nil ? nil : host.id
        }
        let log = Logger(subsystem: "com.caterm.app", category: "cloudkit-sync")
        for host in sessionStore.hosts where host.credentialMaterialDirty {
            do {
                try await sessionStore.clearCredentialMaterialDirty(host.id)
            } catch {
                // Best-effort pre-clear; the durable DeletionProgress list is
                // the authoritative driver. Log so a persistent failure is
                // diagnosable rather than silently allowing a re-push.
                log.error("destructive-deletion: pre-clear dirty bit failed for \(host.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
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
