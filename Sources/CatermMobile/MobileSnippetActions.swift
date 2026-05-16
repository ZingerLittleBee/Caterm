import Foundation
import SnippetSyncClient

public enum MobileSnippetRoute: Hashable {
	case detail(UUID)
	case edit(UUID)
	case terminalPlaceholder(UUID)
	case hostTerminal(hostId: UUID, snippetId: UUID)
}

public enum MobileSnippetActions {
	public static func canCopy(_ snippet: Snippet) -> Bool {
		!snippet.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	public static func runRoute(for snippet: Snippet, targetHostId: UUID?) -> MobileSnippetRoute {
		guard let targetHostId else {
			return .terminalPlaceholder(snippet.id)
		}
		return .hostTerminal(hostId: targetHostId, snippetId: snippet.id)
	}

	public static func editRoute(for snippet: Snippet) -> MobileSnippetRoute {
		.edit(snippet.id)
	}
}
