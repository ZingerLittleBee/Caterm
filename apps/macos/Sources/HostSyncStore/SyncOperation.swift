import Foundation
import ServerSyncClient

/// One discrete sync action emitted by `HostSyncReconciler`. The coordinator
/// that runs them holds both the SessionStore (for local mutations) and a
/// `ServerSyncClient` (for remote mutations).
public enum SyncOperation: Equatable {
    /// A local-only host needs to be created on the server. Caller will
    /// then write the returned serverId back to the local host.
    case createRemote(localHostId: UUID)
    /// A server-only host needs to be created locally. Caller will allocate
    /// a fresh local UUID, copy metadata from `remote`, and stamp serverId.
    case createLocal(remote: RemoteHost)
    /// Local metadata is newer than server's. Push local → server via update.
    case updateRemote(localHostId: UUID, serverId: String)
    /// Server metadata is newer than local's. Apply remote → local.
    case updateLocal(localHostId: UUID, remote: RemoteHost)
    /// Local host was synced before but is gone from server (other device
    /// deleted it). Delete locally.
    case deleteLocal(localHostId: UUID)
    /// Plan C — emitted by HostSyncStore (NOT by HostSyncReconciler) from
    /// the cycle-start dirty scan, after the reconciler's metadata ops.
    /// Executor reads Keychain + ManagedKeyStore live and pushes encrypted
    /// blob via partial CKRecord update.
    case updateRemoteCredentials(localHostId: UUID)
}
