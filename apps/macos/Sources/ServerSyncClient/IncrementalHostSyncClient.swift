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
	public let checkpoint: (any HostSyncCheckpoint)?
	public let tokenExpired: Bool
	public let mode: HostSyncMode

	public init(changedHosts: [RemoteHost],
	            deletedHostIDs: [String],
	            checkpoint: (any HostSyncCheckpoint)?,
	            tokenExpired: Bool,
	            mode: HostSyncMode) {
		self.changedHosts = changedHosts
		self.deletedHostIDs = deletedHostIDs
		self.checkpoint = checkpoint
		self.tokenExpired = tokenExpired
		self.mode = mode
	}
}

public protocol IncrementalHostSyncClient: ServerSyncClient {
	func preferredHostSyncMode() async -> HostSyncMode
	func fetchHostChanges() async throws -> HostChangeBatch
	func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch
	func commitHostCheckpoint(_ checkpoint: any HostSyncCheckpoint) async throws
	func resetHostSyncState() async
	func ensureHostSubscription() async throws
	func deleteHostSubscription() async throws

	/// Plan C — partial-update credential push.
	///
	/// Implementations must honor the §Seed-before-credential-save invariant:
	/// if the existing record has no `metadataUpdatedAt`, seed it from
	/// modificationDate/creationDate (falling back to `.distantPast`)
	/// BEFORE applying the credential blob, in the same client-side
	/// mutation, then save the record exactly once. Returns
	/// `blob.revision` on success.
	func pushHostCredentialBlob(
		serverId: String,
		blob: CredentialBlob
	) async throws -> Int64
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
