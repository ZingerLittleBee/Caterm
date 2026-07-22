import Foundation

public typealias TaskId = UUID

public enum TransferState: Equatable, Sendable {
	case pending
	case running(TransferProgress)
	case conflict(TransferConflict)
	case completed(TransferProgress)
	case failed(RemoteFileError, TransferProgress)
	case cancelled(TransferProgress)
}

public struct TransferTask: Identifiable, Equatable, Sendable {
	public let id: TaskId
	public enum Kind: Equatable, Sendable { case upload, download }
	public enum Status: Equatable, Sendable {
		case pending
		case running
		case conflict
		case completed
		case failed
		case cancelled
	}
	public let kind: Kind
	public let hostId: UUID
	public let source: String
	public internal(set) var destination: String
	public internal(set) var isDirectory: Bool
	public internal(set) var state: TransferState
	public internal(set) var conflictPolicy: TransferConflictPolicy?
	public internal(set) var attemptCount: Int

	public var status: Status {
		switch state {
		case .pending: .pending
		case .running: .running
		case .conflict: .conflict
		case .completed: .completed
		case .failed: .failed
		case .cancelled: .cancelled
		}
	}

	public var progress: TransferProgress {
		switch state {
		case .pending, .conflict:
			.zero
		case .running(let progress), .completed(let progress),
		     .failed(_, let progress), .cancelled(let progress):
			progress
		}
	}

	public var failure: RemoteFileError? {
		guard case .failed(let failure, _) = state else { return nil }
		return failure
	}

	public var conflict: TransferConflict? {
		guard case .conflict(let conflict) = state else { return nil }
		return conflict
	}

	public var error: String? {
		failure?.localizedDescription
	}

	public init(id: TaskId, kind: Kind, hostId: UUID, source: String,
	            destination: String, isDirectory: Bool,
	            state: TransferState = .pending,
	            conflictPolicy: TransferConflictPolicy? = nil,
	            attemptCount: Int = 0) {
		self.id = id
		self.kind = kind
		self.hostId = hostId
		self.source = source
		self.destination = destination
		self.isDirectory = isDirectory
		self.state = state
		self.conflictPolicy = conflictPolicy
		self.attemptCount = max(0, attemptCount)
	}
}
