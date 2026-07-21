import Combine
import Foundation

public struct SessionHistoryHost: Codable, Equatable, Sendable {
	public let savedHostID: UUID?
	public let displayName: String
	public let hostname: String
	public let port: Int
	public let username: String

	public init(
		savedHostID: UUID?,
		displayName: String,
		hostname: String,
		port: Int,
		username: String
	) {
		self.savedHostID = savedHostID
		self.displayName = displayName
		self.hostname = hostname
		self.port = port
		self.username = username
	}
}

public enum SessionHistoryConnectionKind: String, Codable, Equatable, Sendable {
	case savedHost
	case oneTime
}

public enum SessionHistoryOutcome: String, Codable, Equatable, Sendable {
	case completed
	case failed
	case cancelled
	case interrupted
}

public enum SessionHistoryState: Codable, Equatable, Sendable {
	case connecting
	case connected(at: Date)
	case ended(
		connectedAt: Date?,
		endedAt: Date,
		outcome: SessionHistoryOutcome
	)
}

public struct SessionHistoryEntry: Codable, Equatable, Identifiable, Sendable {
	public let id: UUID
	public let host: SessionHistoryHost
	public let connectionKind: SessionHistoryConnectionKind
	public let startedAt: Date
	public var state: SessionHistoryState

	public init(
		id: UUID,
		host: SessionHistoryHost,
		connectionKind: SessionHistoryConnectionKind,
		startedAt: Date,
		state: SessionHistoryState
	) {
		self.id = id
		self.host = host
		self.connectionKind = connectionKind
		self.startedAt = startedAt
		self.state = state
	}

	public var duration: TimeInterval? {
		guard case .ended(_, let endedAt, _) = state else {
			return nil
		}
		return max(0, endedAt.timeIntervalSince(startedAt))
	}
}

private struct SessionHistoryEnvelope: Codable {
	let schemaVersion: Int
	let entries: [SessionHistoryEntry]
}

@MainActor
public protocol SessionHistoryRecording: AnyObject {
	@discardableResult
	func begin(
		host: SessionHistoryHost,
		connectionKind: SessionHistoryConnectionKind,
		at startedAt: Date
	) throws -> UUID

	func markConnected(id: UUID, at connectedAt: Date) throws

	func finish(
		id: UUID,
		outcome: SessionHistoryOutcome,
		at endedAt: Date
	) throws
}

@MainActor
public final class SessionHistoryStore: ObservableObject, SessionHistoryRecording {
	@Published public private(set) var entries: [SessionHistoryEntry] = []

	private static let schemaVersion = 1
	private let fileURL: URL
	private let retentionLimit: Int

	public init(fileURL: URL, retentionLimit: Int = 200) {
		self.fileURL = fileURL
		self.retentionLimit = max(1, retentionLimit)
	}

	public func load(recoveringAt recoveredAt: Date? = nil) throws {
		guard FileManager.default.fileExists(atPath: fileURL.path) else {
			entries = []
			return
		}
		let data = try Data(contentsOf: fileURL)
		let envelope = try JSONDecoder().decode(SessionHistoryEnvelope.self, from: data)
		let retainedEntries = Array(envelope.entries.prefix(retentionLimit))
		guard let recoveredAt else {
			entries = retainedEntries
			return
		}
		var recoveredEntries = retainedEntries
		var didRecover = false
		for index in recoveredEntries.indices {
			switch recoveredEntries[index].state {
			case .connecting:
				recoveredEntries[index].state = .ended(
					connectedAt: nil,
					endedAt: recoveredAt,
					outcome: .interrupted
				)
				didRecover = true
			case .connected(let connectedAt):
				recoveredEntries[index].state = .ended(
					connectedAt: connectedAt,
					endedAt: recoveredAt,
					outcome: .interrupted
				)
				didRecover = true
			case .ended:
				break
			}
		}
		if didRecover {
			try persist(recoveredEntries)
		}
		entries = recoveredEntries
	}

	@discardableResult
	public func begin(
		host: SessionHistoryHost,
		connectionKind: SessionHistoryConnectionKind,
		at startedAt: Date
	) throws -> UUID {
		let id = UUID()
		let entry = SessionHistoryEntry(
			id: id,
			host: host,
			connectionKind: connectionKind,
			startedAt: startedAt,
			state: .connecting
		)
		let updated = Array(([entry] + entries).prefix(retentionLimit))
		try persist(updated)
		entries = updated
		return id
	}

	public func clear() throws {
		try persist([])
		entries = []
	}

	public func markConnected(id: UUID, at connectedAt: Date) throws {
		try update(id: id) { entry in
			guard case .connecting = entry.state else {
				return
			}
			entry.state = .connected(at: connectedAt)
		}
	}

	public func finish(
		id: UUID,
		outcome: SessionHistoryOutcome,
		at endedAt: Date
	) throws {
		try update(id: id) { entry in
			switch entry.state {
			case .connecting:
				entry.state = .ended(
					connectedAt: nil,
					endedAt: endedAt,
					outcome: outcome
				)
			case .connected(let connectedAt):
				entry.state = .ended(
					connectedAt: connectedAt,
					endedAt: endedAt,
					outcome: outcome
				)
			case .ended:
				return
			}
		}
	}

	private func update(
		id: UUID,
		transform: (inout SessionHistoryEntry) -> Void
	) throws {
		guard let index = entries.firstIndex(where: { $0.id == id }) else {
			return
		}
		var updated = entries
		transform(&updated[index])
		guard updated[index] != entries[index] else {
			return
		}
		try persist(updated)
		entries = updated
	}

	private func persist(_ entries: [SessionHistoryEntry]) throws {
		let directory = fileURL.deletingLastPathComponent()
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		let envelope = SessionHistoryEnvelope(
			schemaVersion: Self.schemaVersion,
			entries: entries
		)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		let data = try encoder.encode(envelope)
		try data.write(to: fileURL, options: .atomic)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o600],
			ofItemAtPath: fileURL.path
		)
	}
}
