import FileTransferStore
import Foundation
import SSHCommandBuilder

public actor MobileDeferredRemoteFileClient: RemoteFileClient {
	private enum ConnectionState {
		case idle
		case connecting(Task<any MobileRemoteFileSession, Error>)
		case ready(any MobileRemoteFileSession)
	}

	private let host: SSHHost
	private let factory: MobileRemoteFileClientFactory
	private var connectionState = ConnectionState.idle

	public init(host: SSHHost, factory: MobileRemoteFileClientFactory) {
		self.host = host
		self.factory = factory
	}

	public func list(_ path: String) async throws -> [RemoteEntry] {
		try await client().list(path)
	}

	public func stat(_ path: String) async throws -> RemoteEntry? {
		try await client().stat(path)
	}

	public func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		replaceExisting: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		try await client().upload(
			localURL: localURL,
			remotePath: remotePath,
			isDirectory: isDirectory,
			resume: resume,
			replaceExisting: replaceExisting,
			progress: progress
		)
	}

	public func download(
		remotePath: String,
		localURL: URL,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		try await client().download(
			remotePath: remotePath,
			localURL: localURL,
			isDirectory: isDirectory,
			resume: resume,
			progress: progress
		)
	}

	public func createDirectory(_ path: String) async throws {
		try await client().createDirectory(path)
	}

	public func rename(from: String, to: String) async throws {
		try await client().rename(from: from, to: to)
	}

	public func delete(_ path: String, isDirectory: Bool) async throws {
		try await client().delete(path, isDirectory: isDirectory)
	}

	private func client() async throws -> any MobileRemoteFileSession {
		switch connectionState {
		case .ready(let session):
			return session
		case .connecting(let task):
			return try await task.value
		case .idle:
			let task = Task { @MainActor [factory, host] in
				try await factory.make(host)
			}
			connectionState = .connecting(task)
			do {
				let created = try await task.value
				connectionState = .ready(created)
				return created
			} catch {
				connectionState = .idle
				throw error
			}
		}
	}
}

public actor MobileTransferWorkspace {
	private let rootURL: URL
	private let fileManager: FileManager

	public init(
		rootURL: URL,
		fileManager: FileManager = .default,
		purgeOrphanedUploads: Bool = false
	) {
		self.rootURL = rootURL
		self.fileManager = fileManager
		if purgeOrphanedUploads {
			let uploads = rootURL.appendingPathComponent("Uploads", isDirectory: true)
			do {
				if fileManager.fileExists(atPath: uploads.path) {
					try fileManager.removeItem(at: uploads)
				}
			} catch {
				NSLog("[MobileTransferWorkspace] Orphan cleanup failed: \(error)")
			}
		}
	}

	public func stageUploads(_ sourceURLs: [URL]) throws -> [URL] {
		let directory = rootURL.appendingPathComponent("Uploads", isDirectory: true)
		try fileManager.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		var staged: [URL] = []
		do {
			for source in sourceURLs {
				let accessed = source.startAccessingSecurityScopedResource()
				defer { if accessed { source.stopAccessingSecurityScopedResource() } }
				let values = try source.resourceValues(forKeys: [
					.isRegularFileKey,
					.nameKey,
				])
				guard values.isRegularFile == true else {
					throw RemoteFileError.unsupported(operation: "directory upload")
				}
				let name = values.name ?? source.lastPathComponent
				let stagingDirectory = directory.appendingPathComponent(
					UUID().uuidString,
					isDirectory: true
				)
				try fileManager.createDirectory(
					at: stagingDirectory,
					withIntermediateDirectories: true
				)
				let destination = stagingDirectory.appendingPathComponent(name)
				staged.append(destination)
				try fileManager.copyItem(at: source, to: destination)
			}
			return staged
		} catch {
			for stagedURL in staged {
				do {
					try fileManager.removeItem(at: stagedURL.deletingLastPathComponent())
				} catch let cleanupError {
					NSLog("[MobileTransferWorkspace] Staging rollback failed: \(cleanupError)")
				}
			}
			if let remote = error as? RemoteFileError { throw remote }
			throw RemoteFileError.localIO(message: error.localizedDescription)
		}
	}

	public func removeCompletedUpload(at sourceURL: URL) throws {
		let uploads = rootURL.appendingPathComponent("Uploads", isDirectory: true)
		let stagingDirectory = sourceURL.deletingLastPathComponent()
		guard stagingDirectory.deletingLastPathComponent().standardizedFileURL
			== uploads.standardizedFileURL else {
			return
		}
		guard fileManager.fileExists(atPath: stagingDirectory.path) else { return }
		try fileManager.removeItem(at: stagingDirectory)
	}

	public func downloadsDirectory() throws -> URL {
		let directory = rootURL.appendingPathComponent("Downloads", isDirectory: true)
		try fileManager.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		return directory
	}
}
