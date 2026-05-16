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
	/// `false` when the local revision is strictly newer and the write was
	/// skipped.  The caller can use the return value to decide whether to clear
	/// a dirty flag — it should only clear when `true` (remote was applied).
	///
	/// Precedence order (mirrors `SnippetSyncReconciler.compare`):
	///   1. revision (higher wins)
	///   2. metadataUpdatedAt (server-authoritative; present > absent)
	///   3. updatedAt
	///   4. tie → remote (cloud) wins
	@discardableResult
	public func applyRemote(_ s: Snippet) throws -> Bool {
		if let idx = snippets.firstIndex(where: { $0.id == s.id }) {
			let local = snippets[idx]
			// Skip if local is strictly newer.
			if isLocalNewer(local: local, remote: s) {
				return false
			}
			snippets[idx] = s
		} else {
			snippets.append(s)
		}
		try writeSnippets()
		return true
	}

	/// Returns true when `local` is strictly newer than `remote` under the
	/// same LWW ordering used by `SnippetSyncReconciler`.
	private func isLocalNewer(local: Snippet, remote: Snippet) -> Bool {
		if local.revision > remote.revision { return true }
		if local.revision < remote.revision { return false }
		// Equal revision — compare metadataUpdatedAt.
		switch (remote.metadataUpdatedAt, local.metadataUpdatedAt) {
		case let (.some(r), .some(l)):
			if l > r { return true }
			if l < r { return false }
		case (.some, nil): return false  // remote has it, local doesn't → remote newer
		case (nil, .some): return true   // local has it, remote doesn't → local newer
		case (nil, nil): break
		}
		// Final tie-break: updatedAt; tie → remote wins (not local-newer).
		return local.updatedAt > remote.updatedAt
	}

	/// Remove the snippet from local state. Also clears any outbox entry —
	/// a tombstone observed in the cloud supersedes our pending delete.
	public func applyRemoteTombstone(id: UUID) throws {
		snippets.removeAll { $0.id == id }
		pendingDeletedSnippetIDs.remove(id)
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
