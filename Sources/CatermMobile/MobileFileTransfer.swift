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
	private let securityScope: MobileSecurityScope

	public init(
		rootURL: URL,
		fileManager: FileManager = .default,
		purgeOrphanedUploads: Bool = false,
		securityScope: MobileSecurityScope = .live
	) {
		self.rootURL = rootURL
		self.fileManager = fileManager
		self.securityScope = securityScope
		if purgeOrphanedUploads {
			for directoryName in ["Staging", "Payloads"] {
				let directory = rootURL.appendingPathComponent(
					directoryName,
					isDirectory: true
				)
				do {
					if fileManager.fileExists(atPath: directory.path) {
						try fileManager.removeItem(at: directory)
					}
				} catch {
					NSLog("[MobileTransferWorkspace] Orphan cleanup failed: \(error)")
				}
			}
		}
	}

	/// Copies security-scoped sources through transient staging, then atomically
	/// promotes them into queue-owned inputs retained for retry until the task is
	/// completed or discarded.
	public func importUploadSources(_ sourceURLs: [URL]) throws -> [URL] {
		let stagingRoot = rootURL.appendingPathComponent("Staging", isDirectory: true)
		let payloadRoot = rootURL.appendingPathComponent("Payloads", isDirectory: true)
		for directory in [stagingRoot, payloadRoot] {
			try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
		}
		var stagingDirectories: [URL] = []
		var payloads: [URL] = []
		do {
			for source in sourceURLs {
				let accessed = securityScope.start(source)
				defer { if accessed { securityScope.stop(source) } }
				let values = try source.resourceValues(forKeys: [
					.isRegularFileKey,
					.nameKey,
				])
				guard values.isRegularFile == true else {
					throw RemoteFileError.unsupported(operation: "directory upload")
				}
				let name = values.name ?? source.lastPathComponent
				let identifier = UUID().uuidString
				let stagingDirectory = stagingRoot.appendingPathComponent(
					identifier,
					isDirectory: true
				)
				stagingDirectories.append(stagingDirectory)
				try fileManager.createDirectory(
					at: stagingDirectory,
					withIntermediateDirectories: true
				)
				let stagedFile = stagingDirectory.appendingPathComponent(name)
				try fileManager.copyItem(at: source, to: stagedFile)
				let payloadDirectory = payloadRoot.appendingPathComponent(
					identifier,
					isDirectory: true
				)
				try fileManager.moveItem(at: stagingDirectory, to: payloadDirectory)
				stagingDirectories.removeAll { $0 == stagingDirectory }
				payloads.append(payloadDirectory.appendingPathComponent(name))
			}
			return payloads
		} catch {
			let cleanupDirectories = stagingDirectories
				+ payloads.map { $0.deletingLastPathComponent() }
			for directory in cleanupDirectories {
				do {
					if fileManager.fileExists(atPath: directory.path) {
						try fileManager.removeItem(at: directory)
					}
				} catch let cleanupError {
					NSLog("[MobileTransferWorkspace] Staging rollback failed: \(cleanupError)")
				}
			}
			if let remote = error as? RemoteFileError { throw remote }
			throw RemoteFileError.localIO(message: error.localizedDescription)
		}
	}

	public func removeUploadPayload(at sourceURL: URL) throws {
		let payloadRoot = rootURL.appendingPathComponent("Payloads", isDirectory: true)
		let payloadDirectory = sourceURL.deletingLastPathComponent()
		guard payloadDirectory.deletingLastPathComponent().standardizedFileURL
			== payloadRoot.standardizedFileURL else {
			return
		}
		guard fileManager.fileExists(atPath: payloadDirectory.path) else { return }
		try fileManager.removeItem(at: payloadDirectory)
	}

	public func downloadsDirectory() throws -> URL {
		let directory = rootURL.appendingPathComponent("Downloads", isDirectory: true)
		try fileManager.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		return directory
	}

	public func prepareExport(
		for task: TransferTask
	) throws -> MobileTransferExport {
		guard task.kind == .download, task.status == .completed else {
			throw RemoteFileError.unsupported(operation: "export unfinished transfer")
		}
		let downloads = rootURL.appendingPathComponent(
			"Downloads",
			isDirectory: true
		).standardizedFileURL
		let fileURL = URL(fileURLWithPath: task.destination).standardizedFileURL
		guard fileURL.deletingLastPathComponent() == downloads else {
			throw RemoteFileError.localIO(
				message: "The completed download is outside Caterm's export workspace."
			)
		}
		let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .nameKey])
		guard values.isRegularFile == true else {
			throw RemoteFileError.notFound(path: fileURL.path)
		}
		return MobileTransferExport(
			fileURL: fileURL,
			suggestedName: values.name ?? fileURL.lastPathComponent
		)
	}
}

public struct MobileTransferExport: Equatable, Sendable {
	public let fileURL: URL
	public let suggestedName: String

	public init(fileURL: URL, suggestedName: String) {
		self.fileURL = fileURL
		self.suggestedName = suggestedName
	}
}

public struct MobileSecurityScope: Sendable {
	let start: @Sendable (URL) -> Bool
	let stop: @Sendable (URL) -> Void

	public static let live = MobileSecurityScope(
		start: { $0.startAccessingSecurityScopedResource() },
		stop: { $0.stopAccessingSecurityScopedResource() }
	)

	init(
		start: @escaping @Sendable (URL) -> Bool,
		stop: @escaping @Sendable (URL) -> Void
	) {
		self.start = start
		self.stop = stop
	}
}

@MainActor
public struct MobileTransferActions {
	private let store: FileTransferStore
	private let workspace: MobileTransferWorkspace

	public init(store: FileTransferStore, workspace: MobileTransferWorkspace) {
		self.store = store
		self.workspace = workspace
	}

	public func canEnqueue(for hostID: UUID) -> Bool {
		store.captureEnqueueContext(for: hostID) != nil
	}

	public func upload(
		sourceURLs: [URL],
		context: MobileFileActionContext
	) async throws -> [TaskId] {
		guard let enqueueContext = store.captureEnqueueContext(
			for: context.host.id
		) else {
			throw RemoteFileError.sessionUnavailable
		}
		let queueInputs = try await workspace.importUploadSources(sourceURLs)
		let ids = store.enqueueUpload(
			localPaths: queueInputs,
			remoteDir: context.parentPath,
			host: context.host,
			expectedContext: enqueueContext
		)
		guard ids.count == queueInputs.count else {
			var cleanupFailures: [String] = []
			for source in queueInputs {
				do {
					try await workspace.removeUploadPayload(at: source)
				} catch {
					cleanupFailures.append(error.localizedDescription)
				}
			}
			if !cleanupFailures.isEmpty {
				throw RemoteFileError.cleanupFailed(
					original: .sessionUnavailable,
					cleanupMessage: cleanupFailures.joined(separator: "\n")
				)
			}
			throw RemoteFileError.sessionUnavailable
		}
		return ids
	}

	public func download(
		remotePaths: [String],
		context: MobileFileActionContext
	) async throws -> [TaskId] {
		guard let enqueueContext = store.captureEnqueueContext(
			for: context.host.id
		) else {
			throw RemoteFileError.sessionUnavailable
		}
		let directory = try await workspace.downloadsDirectory()
		let ids = store.enqueueDownload(
			remotePaths: remotePaths,
			localDir: directory,
			host: context.host,
			expectedContext: enqueueContext
		)
		guard ids.count == remotePaths.count else {
			throw RemoteFileError.sessionUnavailable
		}
		return ids
	}

	public func prepareExport(for task: TransferTask) async throws -> MobileTransferExport {
		try await workspace.prepareExport(for: task)
	}

	public func resolveConflict(
		_ id: TaskId,
		policy: TransferConflictPolicy
	) {
		store.resolveConflict(id, policy: policy)
	}

	public func cancel(_ id: TaskId) {
		store.cancel(id)
	}

	public func retry(_ id: TaskId) {
		store.retry(id)
	}

	public func discard(_ id: TaskId) async {
		await store.discard(id)
	}
}

public enum MobileTransferSceneState: Equatable, Sendable {
	case active
	case inactive
	case background
}

@MainActor
public final class MobileTransferLifecycleCoordinator {
	private let store: FileTransferStore
	private let becameActive: @MainActor () async -> Void
	private var sceneStates: [UUID: MobileTransferSceneState] = [:]
	private var applicationIsForeground = false

	public init(
		store: FileTransferStore,
		becameActive: @escaping @MainActor () async -> Void = {}
	) {
		self.store = store
		self.becameActive = becameActive
		store.interruptForBackground()
	}

	public func updateScene(_ sceneID: UUID, state: MobileTransferSceneState) {
		sceneStates[sceneID] = state
		reconcileApplicationState()
	}

	public func unregisterScene(_ sceneID: UUID) {
		let removedState = sceneStates.removeValue(forKey: sceneID)
		guard removedState != nil else { return }
		reconcileApplicationState(closedScene: true)
	}

	private func reconcileApplicationState(closedScene: Bool = false) {
		if sceneStates.values.contains(.active) {
			guard !applicationIsForeground else { return }
			applicationIsForeground = true
			store.reconcileAfterForeground()
			Task { await becameActive() }
			return
		}
		let allRemainingScenesAreBackground = !sceneStates.isEmpty
			&& sceneStates.values.allSatisfy { $0 == .background }
		guard applicationIsForeground,
			allRemainingScenesAreBackground || (closedScene && sceneStates.isEmpty) else {
			return
		}
		applicationIsForeground = false
		store.interruptForBackground()
	}
}
