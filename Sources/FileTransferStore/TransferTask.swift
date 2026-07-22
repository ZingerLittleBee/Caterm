import Foundation

public typealias TaskId = UUID

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
	public var destination: String
	public let isDirectory: Bool
	public var status: Status
	public var error: String?
	public var failure: RemoteFileError?
	public var conflict: TransferConflict?
	public var progress: TransferProgress
	public var conflictPolicy: TransferConflictPolicy?
	public var attemptCount: Int

	public init(id: TaskId, kind: Kind, hostId: UUID, source: String,
	            destination: String, isDirectory: Bool,
	            status: Status, error: String?,
	            failure: RemoteFileError? = nil,
	            conflict: TransferConflict? = nil,
	            progress: TransferProgress = TransferProgress(
	             bytesTransferred: 0,
	             totalBytes: nil
	            ),
	            conflictPolicy: TransferConflictPolicy? = nil,
	            attemptCount: Int = 0) {
		self.id = id
		self.kind = kind
		self.hostId = hostId
		self.source = source
		self.destination = destination
		self.isDirectory = isDirectory
		self.status = status
		self.error = error
		self.failure = failure
		self.conflict = conflict
		self.progress = progress
		self.conflictPolicy = conflictPolicy
		self.attemptCount = max(0, attemptCount)
	}
}
