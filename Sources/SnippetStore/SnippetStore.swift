import Combine
import Foundation
import MergeDecision
import SnippetSyncClient

public enum SnippetStoreError: Error, Equatable {
	case writeFailed(String)
	case readFailed(String)
}

private struct SnippetsEnvelope: Codable {
	let schemaVersion: Int
	let snippets: [Snippet]
	let locallyDirtySnippetIDs: [UUID]?
}

private struct OutboxEnvelope: Codable {
	let schemaVersion: Int
	let pendingDeletedSnippetIDs: [UUID]
}

@MainActor
public final class SnippetStore: ObservableObject {
	@Published public private(set) var snippets: [Snippet] = []
	@Published public private(set) var pendingDeletedSnippetIDs: Set<UUID> = []
	/// Local edits awaiting a successful CloudKit acknowledgement. Stored in
	/// snippets.json with the content so a relaunch cannot lose push intent.
	@Published public private(set) var locallyDirtySnippetIDs: Set<UUID> = []

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
			self.locallyDirtySnippetIDs = Set(env.locallyDirtySnippetIDs ?? [])
		}
		if let data = try? Data(contentsOf: outboxURL) {
			let env = try JSONDecoder().decode(OutboxEnvelope.self, from: data)
			self.pendingDeletedSnippetIDs = Set(env.pendingDeletedSnippetIDs)
		}
	}

	public func upsert(_ s: Snippet) throws {
		let originalSnippets = snippets
		let originalDirtyIDs = locallyDirtySnippetIDs
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
		locallyDirtySnippetIDs.insert(copy.id)
		do {
			try writeSnippets()
		} catch {
			snippets = originalSnippets
			locallyDirtySnippetIDs = originalDirtyIDs
			throw error
		}
	}

	public func delete(id: UUID) throws {
		snippets.removeAll { $0.id == id }
		locallyDirtySnippetIDs.remove(id)
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
		locallyDirtySnippetIDs = []
		try writeSnippets()
		try writeOutbox()
	}

	public func search(_ query: String) -> [Snippet] {
		let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return snippets }
		let needle = trimmed.lowercased()
		return snippets.filter {
			$0.name.lowercased().contains(needle)
				|| $0.content.lowercased().contains(needle)
		}
	}

	/// Apply a server-authoritative snippet using LWW precedence.
	///
	/// Returns `true` when the remote snippet was written (remote wins or new),
	/// `false` when the local copy is newer under the shared precedence and the
	/// write was skipped. The caller can use the return value to decide whether to clear
	/// a dirty flag — it should only clear when `true` (remote was applied).
	///
	/// Precedence order (owned by `SnippetMergePolicy`):
	///   1. revision (higher wins)
	///   2. metadataUpdatedAt (server-authoritative; present > absent)
	///   3. updatedAt
	///   4. tie → remote (cloud) wins
	@discardableResult
	public func applyRemote(_ s: Snippet) throws -> Bool {
		let originalSnippets = snippets
		let originalDirtyIDs = locallyDirtySnippetIDs
		let index = SnippetMergePolicy.makeIdentityIndex(snippets)
		if let local = SnippetMergePolicy.match(s, in: index),
		   let idx = snippets.firstIndex(where: { $0.id == local.id }) {
			if SnippetMergePolicy.decide(local: local, incoming: s) == .local {
				return false
			}
			snippets[idx] = s
		} else {
			snippets.append(s)
		}
		locallyDirtySnippetIDs.remove(s.id)
		do {
			try writeSnippets()
		} catch {
			snippets = originalSnippets
			locallyDirtySnippetIDs = originalDirtyIDs
			throw error
		}
		return true
	}

	/// Remove the snippet from local state. Also clears any outbox entry —
	/// a tombstone observed in the cloud supersedes our pending delete.
	public func applyRemoteTombstone(id: UUID) throws {
		snippets.removeAll { $0.id == id }
		pendingDeletedSnippetIDs.remove(id)
		locallyDirtySnippetIDs.remove(id)
		try writeSnippets()
		try writeOutbox()
	}

	// MARK: - Persistence

	private func writeSnippets() throws {
		let env = SnippetsEnvelope(
			schemaVersion: Self.schemaVersion,
			snippets: snippets,
			locallyDirtySnippetIDs: locallyDirtySnippetIDs.sorted {
				$0.uuidString < $1.uuidString
			}
		)
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
