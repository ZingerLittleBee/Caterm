import CatermMobileTerminal
import FileTransferStore
import Foundation
import SSHCommandBuilder

public protocol MobileRemoteFileSession: RemoteFileClient {
	func disconnect() async
}

public struct MobileRemoteFileClientFactory: Sendable {
	public let make: @MainActor @Sendable (SSHHost) async throws -> any MobileRemoteFileSession

	public init(
		make: @escaping @MainActor @Sendable (SSHHost) async throws -> any MobileRemoteFileSession
	) {
		self.make = make
	}

	public static let unavailable = MobileRemoteFileClientFactory { _ in
		throw RemoteFileError.unsupported(operation: "mobile SFTP")
	}
}

public actor MobileRemoteFileClient: MobileRemoteFileSession {
	private let host: SSHHost
	private let plan: SSHAuthPlan
	private let knownHosts: MobileKnownHostsStore
	private var client: MobileSFTPClient?

	public init(
		host: SSHHost,
		plan: SSHAuthPlan,
		knownHosts: MobileKnownHostsStore
	) {
		self.host = host
		self.plan = plan
		self.knownHosts = knownHosts
	}

	public func list(_ path: String) async throws -> [RemoteEntry] {
		do {
			let client = try await connectedClient()
			return try await client.listDirectory(at: path).map(\.remoteEntry)
		} catch {
			if Self.invalidatesSession(error) {
				client?.close()
				client = nil
			}
			throw map(error, path: path)
		}
	}

	public func stat(_ path: String) async throws -> RemoteEntry? {
		do {
			let client = try await connectedClient()
			return try await client.stat(at: path).remoteEntry
		} catch MobileSFTPError.notFound {
			return nil
		} catch {
			if Self.invalidatesSession(error) {
				client?.close()
				client = nil
			}
			throw map(error, path: path)
		}
	}

	public func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		replaceExisting: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		guard !isDirectory else {
			throw RemoteFileError.unsupported(operation: "directory upload")
		}
		_ = resume
		do {
			let client = try await connectedClient()
			let transferred = try await client.upload(
				localURL: localURL,
				remotePath: remotePath,
				replaceExisting: replaceExisting,
				progress: { update in
					await progress(TransferProgress(
						bytesTransferred: update.bytesTransferred,
						totalBytes: update.totalBytes
					))
				}
			)
			return RemoteFileTransferResult(bytesTransferred: transferred)
		} catch {
			if Self.invalidatesSession(error) {
				client?.close()
				client = nil
			}
			throw map(error, path: remotePath)
		}
	}

	public func download(
		remotePath: String,
		localURL: URL,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		guard !isDirectory else {
			throw RemoteFileError.unsupported(operation: "directory download")
		}
		_ = resume
		do {
			let client = try await connectedClient()
			let transferred = try await client.download(
				remotePath: remotePath,
				localURL: localURL,
				progress: { update in
					await progress(TransferProgress(
						bytesTransferred: update.bytesTransferred,
						totalBytes: update.totalBytes
					))
				}
			)
			return RemoteFileTransferResult(bytesTransferred: transferred)
		} catch {
			if Self.invalidatesSession(error) {
				client?.close()
				client = nil
			}
			throw map(error, path: remotePath)
		}
	}

	public func createDirectory(_ path: String) async throws {
		try await mutate(path: path) { try await $0.createDirectory(at: path) }
	}

	public func rename(from: String, to: String) async throws {
		try await mutate(path: from) { try await $0.rename(from: from, to: to) }
	}

	public func delete(_ path: String, isDirectory: Bool) async throws {
		try await mutate(path: path) { try await $0.delete(at: path, isDirectory: isDirectory) }
	}

	public func disconnect() {
		client?.close()
		client = nil
	}

	private func connectedClient() async throws -> MobileSFTPClient {
		if let client { return client }
		let connected = try await MobileSFTPClient.connect(
			host: host,
			plan: plan,
			knownHosts: knownHosts
		)
		client = connected
		return connected
	}

	private func map(_ error: Error, path: String) -> RemoteFileError {
		switch error {
		case MobileSFTPError.cancelled:
			.cancelled
		case MobileSFTPError.permissionDenied(let message):
			.permissionDenied(message: message)
		case MobileSFTPError.notFound:
			.notFound(path: path)
		case MobileSFTPError.alreadyExists(let path):
			.conflict(path: path)
		case MobileSFTPError.directoryNotEmpty(let path):
			.directoryNotEmpty(path: path)
		case MobileSFTPError.disconnected:
			.sessionUnavailable
		case MobileSFTPError.localIO(let message):
			.localIO(message: message)
		case MobileSFTPError.cleanupFailed(let original, let cleanupMessage):
			.cleanupFailed(
				original: map(original, path: path),
				cleanupMessage: cleanupMessage
			)
		case MobileSSHTrustError.changed(let endpoint):
			.hostKeyChanged(endpoint: endpoint)
		case MobileSSHTrustError.persistenceFailed(let endpoint):
			.hostKeyPersistenceFailed(endpoint: endpoint)
		case let key as MobileSSHPrivateKeyError:
			.transport(message: key.localizedDescription)
		case let sftp as MobileSFTPError:
			.transport(message: sftp.localizedDescription)
		case is CancellationError:
			.cancelled
		default:
			.transport(message: error.localizedDescription)
		}
	}

	private func mutate(
		path: String,
		operation: @escaping @Sendable (MobileSFTPClient) async throws -> Void
	) async throws {
		do {
			let client = try await connectedClient()
			try await operation(client)
		} catch {
			if Self.invalidatesSession(error) {
				client?.close()
				client = nil
			}
			throw map(error, path: path)
		}
	}

	private static func invalidatesSession(_ error: Error) -> Bool {
		if error is CancellationError { return true }
		switch error {
		case MobileSFTPError.cancelled,
		     MobileSFTPError.disconnected,
		     MobileSFTPError.cleanupFailed:
			return true
		default:
			return false
		}
	}
}

private extension MobileSFTPEntryType {
	var remoteEntryType: RemoteEntryType {
		switch self {
		case .file: .file
		case .directory: .directory
		case .unknown: .unknown
		}
	}
}

private extension MobileSFTPEntry {
	var remoteEntry: RemoteEntry {
		RemoteEntry(
			name: name,
			type: type.remoteEntryType,
			size: size,
			mtime: modificationDate,
			mode: permissions,
			canonicalPath: path
		)
	}
}
