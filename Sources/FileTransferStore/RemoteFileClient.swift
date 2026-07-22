import Foundation

public struct TransferProgress: Equatable, Sendable {
	public static let zero = TransferProgress(
		bytesTransferred: 0,
		totalBytes: nil
	)

	public let bytesTransferred: Int64
	public let totalBytes: Int64?

	public init(bytesTransferred: Int64, totalBytes: Int64?) {
		self.bytesTransferred = max(0, bytesTransferred)
		self.totalBytes = totalBytes.map { max(0, $0) }
	}

	public func advancing(to update: TransferProgress) -> TransferProgress {
		let bytes = max(bytesTransferred, update.bytesTransferred)
		let total = update.totalBytes ?? totalBytes
		return TransferProgress(
			bytesTransferred: bytes,
			totalBytes: total.map { max($0, bytes) }
		)
	}
}

public typealias TransferProgressHandler = @Sendable (TransferProgress) async -> Void

public struct RemoteFileTransferResult: Equatable, Sendable {
	public let bytesTransferred: Int64

	public init(bytesTransferred: Int64) {
		self.bytesTransferred = max(0, bytesTransferred)
	}
}

public enum RemoteFileError: Error, Equatable, Sendable {
	case cancelled
	case sessionUnavailable
	case hostKeyChanged(endpoint: String)
	case hostKeyPersistenceFailed(endpoint: String)
	case permissionDenied(message: String)
	case notFound(path: String)
	case unsupported(operation: String)
	case transport(message: String)
	case invalidResponse(message: String)
	case localIO(message: String)
	indirect case cleanupFailed(original: RemoteFileError, cleanupMessage: String)
}

extension RemoteFileError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .cancelled:
			"Transfer cancelled"
		case .sessionUnavailable:
			"SSH session is no longer available"
		case .hostKeyChanged(let endpoint):
			"The SSH host key changed for \(endpoint)."
		case .hostKeyPersistenceFailed(let endpoint):
			"Caterm could not save the SSH host key for \(endpoint)."
		case .permissionDenied(let message):
			message
		case .notFound(let path):
			"Remote path not found: \(path)"
		case .unsupported(let operation):
			"Remote file operation is unsupported: \(operation)"
		case .transport(let message),
		     .invalidResponse(let message),
		     .localIO(let message):
			message
		case .cleanupFailed(let original, let cleanupMessage):
			"\(original.localizedDescription). Partial-file cleanup failed: \(cleanupMessage)"
		}
	}
}

/// Transport-independent remote-file behavior. Implementations own SSH and
/// SFTP details; callers observe only file operations, progress, and typed
/// failures. Cancelling the calling task must cancel the active operation.
public protocol RemoteFileClient: Sendable {
	func list(_ path: String) async throws -> [RemoteEntry]
	func stat(_ path: String) async throws -> RemoteEntry?
	func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult
	func download(
		remotePath: String,
		localURL: URL,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult
	func createDirectory(_ path: String) async throws
	func rename(from: String, to: String) async throws
	func delete(_ path: String, isDirectory: Bool) async throws
}

public enum TransferConflictPolicy: Equatable, Sendable {
	case replace
	case keepBoth
	case cancel
}

public struct TransferConflict: Equatable, Sendable {
	public let destination: String

	public init(destination: String) {
		self.destination = destination
	}
}
