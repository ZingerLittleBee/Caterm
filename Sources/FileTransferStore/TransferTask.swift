import Foundation

public typealias TaskId = UUID

public struct TransferTask: Identifiable, Equatable {
	public let id: TaskId
	public enum Kind: Equatable { case upload, download }
	public enum Status: Equatable { case pending, running, completed, failed, cancelled }
	public let kind: Kind
	public let hostId: UUID
	public let source: String
	public let destination: String
	public let isDirectory: Bool
	public var status: Status
	public var error: String?

	public init(id: TaskId, kind: Kind, hostId: UUID, source: String,
	            destination: String, isDirectory: Bool,
	            status: Status, error: String?) {
		self.id = id
		self.kind = kind
		self.hostId = hostId
		self.source = source
		self.destination = destination
		self.isDirectory = isDirectory
		self.status = status
		self.error = error
	}
}
