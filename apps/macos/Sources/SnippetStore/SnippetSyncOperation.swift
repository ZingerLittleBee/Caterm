import Foundation
import SnippetSyncClient

public enum SnippetSyncOperation: Sendable, Equatable {
	case applyRemote(Snippet)
	case applyTombstone(id: UUID)
	case pushLocal(Snippet)
}
