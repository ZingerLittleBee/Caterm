import Foundation

public enum SnippetSyncMode: Sendable, Equatable {
	case incremental
	case forceFull
}

public protocol SnippetSyncCheckpoint: Sendable {
	var id: UUID { get }
}

public struct SnippetChangeBatch: Sendable {
	public let changedSnippets: [Snippet]
	public let deletedSnippetIDs: [UUID]
	public let checkpoint: (any SnippetSyncCheckpoint)?
	public let tokenExpired: Bool
	public let mode: SnippetSyncMode

	public init(
		changedSnippets: [Snippet],
		deletedSnippetIDs: [UUID],
		checkpoint: (any SnippetSyncCheckpoint)?,
		tokenExpired: Bool,
		mode: SnippetSyncMode
	) {
		self.changedSnippets = changedSnippets
		self.deletedSnippetIDs = deletedSnippetIDs
		self.checkpoint = checkpoint
		self.tokenExpired = tokenExpired
		self.mode = mode
	}
}
