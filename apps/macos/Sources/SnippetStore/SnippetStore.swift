import Combine
import Foundation
import SnippetSyncClient

@MainActor
public final class SnippetStore: ObservableObject {
	@Published public private(set) var snippets: [Snippet] = []
	@Published public private(set) var pendingDeletedSnippetIDs: Set<UUID> = []

	private let snippetsURL: URL
	private let outboxURL: URL

	public init(directory: URL) {
		self.snippetsURL = directory.appendingPathComponent("snippets.json")
		self.outboxURL = directory.appendingPathComponent("snippets.outbox.json")
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}
}
