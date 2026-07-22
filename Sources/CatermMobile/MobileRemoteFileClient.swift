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
			return try await client.listDirectory(at: path).map {
				RemoteEntry(
					name: $0.name,
					type: $0.type.remoteEntryType,
					size: $0.size,
					mtime: $0.modificationDate,
					mode: $0.permissions,
					canonicalPath: $0.path
				)
			}
		} catch {
			if Self.invalidatesSession(error) {
				client?.close()
				client = nil
			}
			throw map(error, path: path)
		}
	}

	public func stat(_ path: String) async throws -> RemoteEntry? {
		throw RemoteFileError.unsupported(operation: "stat")
	}

	public func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		throw RemoteFileError.unsupported(operation: "upload")
	}

	public func download(
		remotePath: String,
		localURL: URL,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		throw RemoteFileError.unsupported(operation: "download")
	}

	public func createDirectory(_ path: String) async throws {
		throw RemoteFileError.unsupported(operation: "create directory")
	}

	public func rename(from: String, to: String) async throws {
		throw RemoteFileError.unsupported(operation: "rename")
	}

	public func delete(_ path: String, isDirectory: Bool) async throws {
		throw RemoteFileError.unsupported(operation: "delete")
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
		case MobileSFTPError.disconnected:
			.sessionUnavailable
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
