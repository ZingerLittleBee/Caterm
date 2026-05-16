import Foundation

public protocol IncrementalSnippetSyncClient: Sendable {
	func preferredSnippetSyncMode() async -> SnippetSyncMode
	func fetchSnippetChanges() async throws -> SnippetChangeBatch
	func fetchSnippetSnapshotAndCheckpoint() async throws -> SnippetChangeBatch
	func commitSnippetCheckpoint(_ checkpoint: any SnippetSyncCheckpoint) async throws
	func resetSnippetSyncState() async
	func ensureSnippetSubscription() async throws
	func deleteSnippetSubscription() async throws
	func pushSnippet(_ snippet: Snippet) async throws -> Snippet
	func deleteSnippet(id: UUID) async throws
	/// Probe whether persisted snippet tokens exist. Used by
	/// `AccountIdentityTracker.tokensExist`.
	func hasAnySnippetSyncTokens() async -> Bool
}
