import CredentialSyncTypes
import Foundation

public enum HostSyncMode: Sendable, Equatable {
	case incremental
	case forceFull
}

public protocol HostSyncCheckpoint: Sendable {
	/// Stable identity for tests / logs. Implementation-defined.
	var id: UUID { get }
}

public struct HostChangeBatch: Sendable {
	public let changedHosts: [RemoteHost]
	public let deletedHostIDs: [String]
	/// Plan C — credential side-table keyed by server (CKRecord) id. Populated
	/// by CloudKit decode; empty for legacy/test producers that don't carry
	/// credential blobs. The default `[:]` preserves every existing
	/// `HostChangeBatch(...)` call site.
	public let credentialBlobsByServerId: [String: CredentialBlob]
	public let checkpoint: (any HostSyncCheckpoint)?
	public let tokenExpired: Bool
	public let mode: HostSyncMode

	public init(changedHosts: [RemoteHost],
	            deletedHostIDs: [String],
	            credentialBlobsByServerId: [String: CredentialBlob] = [:],
	            checkpoint: (any HostSyncCheckpoint)?,
	            tokenExpired: Bool,
	            mode: HostSyncMode) {
		self.changedHosts = changedHosts
		self.deletedHostIDs = deletedHostIDs
		self.credentialBlobsByServerId = credentialBlobsByServerId
		self.checkpoint = checkpoint
		self.tokenExpired = tokenExpired
		self.mode = mode
	}
}

/// Narrow transport seam for credential-only record updates.
public protocol CredentialBlobPushing: Sendable {
	/// Implementations must seed missing metadata timestamps before applying
	/// the credential blob, then persist both changes in one remote mutation.
	func pushHostCredentialBlob(
		serverId: String,
		blob: CredentialBlob
	) async throws -> Int64
}

public protocol IncrementalHostSyncClient: ServerSyncClient, CredentialBlobPushing {
	func preferredHostSyncMode() async -> HostSyncMode
	func fetchHostChanges() async throws -> HostChangeBatch
	func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch
	func commitHostCheckpoint(_ checkpoint: any HostSyncCheckpoint) async throws
	func resetHostSyncState() async
	func ensureHostSubscription() async throws
	func deleteHostSubscription() async throws
}

/// Default-throwing implementation provided so existing fakes that don't
/// override `pushHostCredentialBlob` continue to compile. Production
/// conformers (e.g. `CloudKitSyncClient`) override this with the real path.
public enum CredentialPushUnimplementedError: Error, Equatable {
	case notImplemented
}

extension IncrementalHostSyncClient {
	public func pushHostCredentialBlob(
		serverId _: String,
		blob _: CredentialBlob
	) async throws -> Int64 {
		throw CredentialPushUnimplementedError.notImplemented
	}
}

extension Notification.Name {
	/// Posted by AppDelegate.application(_:didReceiveRemoteNotification:)
	/// when a CKDatabaseSubscription notification matching the Host
	/// subscription ID arrives. Observed by HostSyncStore.
	public static let catermCloudKitHostChanged =
		Notification.Name("catermCloudKitHostChanged")
}
