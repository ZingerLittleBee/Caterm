import Combine
import Foundation
import SnippetSyncClient

public enum SnippetStoreError: Error, Equatable {
	case writeFailed(String)
	case readFailed(String)
}

private struct SnippetsEnvelope: Codable {
	let schemaVersion: Int
	let snippets: [Snippet]
}

private struct OutboxEnvelope: Codable {
	let schemaVersion: Int
	let pendingDeletedSnippetIDs: [UUID]
}

@MainActor
public final class SnippetStore: ObservableObject {
	@Published public private(set) var snippets: [Snippet] = []
	@Published public private(set) var pendingDeletedSnippetIDs: Set<UUID> = []

	private let snippetsURL: URL
	private let outboxURL: URL
	private static let schemaVersion = 1

	public init(directory: URL) {
		self.snippetsURL = directory.appendingPathComponent("snippets.json")
		self.outboxURL = directory.appendingPathComponent("snippets.outbox.json")
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	public func load() throws {
		if let data = try? Data(contentsOf: snippetsURL) {
			let env = try JSONDecoder().decode(SnippetsEnvelope.self, from: data)
			self.snippets = env.snippets
		}
		if let data = try? Data(contentsOf: outboxURL) {
			let env = try JSONDecoder().decode(OutboxEnvelope.self, from: data)
			self.pendingDeletedSnippetIDs = Set(env.pendingDeletedSnippetIDs)
		}
	}

	public func upsert(_ s: Snippet) throws {
		var copy = s
		if let existingIdx = snippets.firstIndex(where: { $0.id == s.id }) {
			let existing = snippets[existingIdx]
			copy.revision = existing.revision + 1
			copy.updatedAt = Date()
			copy.createdAt = existing.createdAt
			snippets[existingIdx] = copy
		} else {
			snippets.append(copy)
		}
		try writeSnippets()
	}

	public func delete(id: UUID) throws {
		snippets.removeAll { $0.id == id }
		pendingDeletedSnippetIDs.insert(id)
		try writeSnippets()
		try writeOutbox()
	}

	public func clearOutboxEntry(_ id: UUID) throws {
		pendingDeletedSnippetIDs.remove(id)
		try writeOutbox()
	}

	public func wipeLocal() throws {
		snippets = []
		pendingDeletedSnippetIDs = []
		try writeSnippets()
		try writeOutbox()
	}

	// MARK: - Persistence

	private func writeSnippets() throws {
		let env = SnippetsEnvelope(schemaVersion: Self.schemaVersion, snippets: snippets)
		try atomicWrite(JSONEncoder().encode(env), to: snippetsURL)
	}

	private func writeOutbox() throws {
		let env = OutboxEnvelope(
			schemaVersion: Self.schemaVersion,
			pendingDeletedSnippetIDs: Array(pendingDeletedSnippetIDs)
		)
		try atomicWrite(JSONEncoder().encode(env), to: outboxURL)
	}

	private func atomicWrite(_ data: Data, to url: URL) throws {
		let tmp = url.appendingPathExtension("tmp")
		do {
			try data.write(to: tmp, options: .atomic)
			_ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
		} catch {
			try? FileManager.default.removeItem(at: tmp)
			throw SnippetStoreError.writeFailed(error.localizedDescription)
		}
	}
}
