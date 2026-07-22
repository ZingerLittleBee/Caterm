import Combine
import Foundation
import SFTPCommandBuilder
import SSHCommandBuilder

@MainActor
public final class FileTransferStore: ObservableObject {
	public typealias ClientFactory = (SSHHost) -> any RemoteFileClient

	@Published public private(set) var tasks: [TransferTask] = []

	private let clientForHost: ClientFactory
	private let localFiles: any LocalTransferFileCoordinating
	private let didComplete: @Sendable (TransferTask) async -> Void
	private var perHostQueues: [UUID: [TaskId]] = [:]
	private var perHostBusy: Set<UUID> = []
	private var perHostHost: [UUID: SSHHost] = [:]
	private var runningJobs: [TaskId: Task<Void, Never>] = [:]

	/// Creates a transport-independent transfer coordinator.
	public init(
		clientForHost: @escaping ClientFactory,
		didComplete: @escaping @Sendable (TransferTask) async -> Void = { _ in }
	) {
		self.clientForHost = clientForHost
		localFiles = LocalTransferFileCoordinator()
		self.didComplete = didComplete
	}

	init(
		clientForHost: @escaping ClientFactory,
		localFiles: any LocalTransferFileCoordinating,
		didComplete: @escaping @Sendable (TransferTask) async -> Void = { _ in }
	) {
		self.clientForHost = clientForHost
		self.localFiles = localFiles
		self.didComplete = didComplete
	}

	/// Preserves the existing macOS composition while adapting OpenSSH SFTP
	/// behind the shared remote-file contract.
	public convenience init(
		controlPathFor: @escaping (UUID) -> URL,
		credentialsFor: @escaping (UUID) -> SFTPCredentials,
		runner: SFTPRunner = DefaultSFTPRunner(),
		liveness: ControlMasterLiveness
	) {
		self.init { host in
			RemoteFileSystem(
				host: host,
				controlPath: controlPathFor(host.id),
				credentials: credentialsFor(host.id),
				runner: runner,
				liveness: liveness
			)
		}
	}

	public func task(id: TaskId) -> TransferTask? {
		tasks.first { $0.id == id }
	}

	public func enqueueUpload(
		localPaths: [URL],
		remoteDir: String,
		host: SSHHost,
		conflictPolicy: TransferConflictPolicy? = nil
	) -> [TaskId] {
		var ids: [TaskId] = []
		perHostHost[host.id] = host
		for path in localPaths {
			let destination = (remoteDir as NSString)
				.appendingPathComponent(path.lastPathComponent)
			let task = TransferTask(
				id: UUID(),
				kind: .upload,
				hostId: host.id,
				source: path.path,
				destination: destination,
				isDirectory: false,
				conflictPolicy: conflictPolicy
			)
			tasks.append(task)
			perHostQueues[host.id, default: []].append(task.id)
			ids.append(task.id)
		}
		kick(host.id)
		return ids
	}

	public func enqueueDownload(
		remotePaths: [String],
		localDir: URL,
		host: SSHHost,
		conflictPolicy: TransferConflictPolicy? = nil
	) -> [TaskId] {
		var ids: [TaskId] = []
		perHostHost[host.id] = host
		for remotePath in remotePaths {
			let destination = localDir.appendingPathComponent(
				(remotePath as NSString).lastPathComponent
			)
			let task = TransferTask(
				id: UUID(),
				kind: .download,
				hostId: host.id,
				source: remotePath,
				destination: destination.path,
				isDirectory: false,
				conflictPolicy: conflictPolicy
			)
			tasks.append(task)
			perHostQueues[host.id, default: []].append(task.id)
			ids.append(task.id)
		}
		kick(host.id)
		return ids
	}

	public func cancel(_ id: TaskId) {
		guard let index = index(of: id) else { return }
		switch tasks[index].status {
		case .pending:
			removeFromQueue(id, hostID: tasks[index].hostId)
			markCancelled(at: index)
		case .running:
			runningJobs[id]?.cancel()
		case .conflict:
			markCancelled(at: index)
		case .completed, .failed, .cancelled:
			break
		}
	}

	public func retry(_ id: TaskId) {
		guard let index = index(of: id),
			[.failed, .cancelled].contains(tasks[index].status) else {
			return
		}
		tasks[index].state = .pending
		tasks[index].attemptCount += 1
		tasks[index].conflictPolicy = nil
		perHostQueues[tasks[index].hostId, default: []].append(id)
		kick(tasks[index].hostId)
	}

	public func resolveConflict(
		_ id: TaskId,
		policy: TransferConflictPolicy
	) {
		guard let index = index(of: id), tasks[index].status == .conflict else {
			return
		}
		if policy == .cancel {
			markCancelled(at: index)
			return
		}
		tasks[index].conflictPolicy = policy
		tasks[index].state = .pending
		perHostQueues[tasks[index].hostId, default: []].append(id)
		kick(tasks[index].hostId)
	}

	public func waitIdle() async throws {
		while !perHostBusy.isEmpty || perHostQueues.values.contains(where: {
			!$0.isEmpty
		}) {
			try await Task.sleep(for: .milliseconds(5))
		}
	}

	private func kick(_ hostID: UUID) {
		guard !perHostBusy.contains(hostID),
		      let next = perHostQueues[hostID]?.first else {
			return
		}
		perHostQueues[hostID]?.removeFirst()
		guard let index = index(of: next) else {
			kick(hostID)
			return
		}

		perHostBusy.insert(hostID)
		tasks[index].state = .running(.zero)
		let job = Task { [weak self] in
			guard let self else { return }
			await self.runTask(id: next)
			self.runningJobs[next] = nil
			self.perHostBusy.remove(hostID)
			self.kick(hostID)
		}
		runningJobs[next] = job
	}

	private func runTask(id: TaskId) async {
		guard let index = index(of: id),
		      let host = perHostHost[tasks[index].hostId] else {
			markFailed(
				id: id,
				failure: .invalidResponse(message: "Missing Host registration")
			)
			return
		}

		let client = clientForHost(host)
		do {
			try Task.checkCancellation()
			switch tasks[index].kind {
			case .upload:
				try await executeUpload(id: id, client: client)
			case .download:
				try await executeDownload(id: id, client: client)
			}
			guard let completedIndex = self.index(of: id),
			      tasks[completedIndex].status == .running else {
				return
			}
			tasks[completedIndex].state = .completed(
				tasks[completedIndex].progress
			)
			await didComplete(tasks[completedIndex])
		} catch is CancellationError {
			markCancelled(id: id)
		} catch RemoteFileError.cancelled {
			markCancelled(id: id)
		} catch RemoteFileError.cleanupFailed(
			let original,
			let cleanupMessage
		) where original == .cancelled {
			NSLog("[FileTransferStore] Cancel cleanup failed: \(cleanupMessage)")
			markCancelled(id: id)
		} catch let failure as RemoteFileError {
			markFailed(id: id, failure: failure)
		} catch {
			markFailed(
				id: id,
				failure: .transport(message: String(describing: error))
			)
		}
	}

	private func executeUpload(
		id: TaskId,
		client: any RemoteFileClient
	) async throws {
		guard let task = task(id: id) else { return }
		let source = URL(fileURLWithPath: task.source)
		let isDirectory: Bool
		do {
			isDirectory = try await localFiles.isDirectory(at: source)
		} catch {
			throw RemoteFileError.localIO(message: error.localizedDescription)
		}
		guard let index = index(of: id) else { return }
		tasks[index].isDirectory = isDirectory
		let preparation = try await prepareRemoteDestination(
			task.destination,
			policy: task.conflictPolicy,
			client: client
		)
		guard let destination = apply(preparation, to: id) else { return }
		let result = try await client.upload(
			localURL: source,
			remotePath: destination,
			isDirectory: isDirectory,
			resume: task.attemptCount > 0,
			replaceExisting: task.conflictPolicy == .replace,
			progress: progressHandler(for: id)
		)
		advanceProgress(
			id: id,
			to: TransferProgress(
				bytesTransferred: result.bytesTransferred,
				totalBytes: result.bytesTransferred
			)
		)
	}

	private func executeDownload(
		id: TaskId,
		client: any RemoteFileClient
	) async throws {
		guard let task = task(id: id) else { return }
		let requested = URL(fileURLWithPath: task.destination)
		let preparation: DestinationPreparation<URL>
		do {
			preparation = try await localFiles.prepareDestination(
				requested,
				policy: task.conflictPolicy
			)
		} catch {
			throw RemoteFileError.localIO(message: error.localizedDescription)
		}
		guard let destination = apply(preparation, to: id) else { return }

		let temporary: URL
		do {
			temporary = try await localFiles.temporaryDestination(for: destination)
		} catch {
			throw RemoteFileError.localIO(message: error.localizedDescription)
		}

		do {
			let result: RemoteFileTransferResult
			do {
				result = try await client.download(
					remotePath: task.source,
					localURL: temporary,
					isDirectory: task.isDirectory,
					resume: false,
					progress: progressHandler(for: id)
				)
			} catch is CancellationError {
				throw CancellationError()
			} catch let failure as RemoteFileError {
				throw failure
			} catch {
				throw RemoteFileError.transport(message: String(describing: error))
			}
			try Task.checkCancellation()
			do {
				try await localFiles.publish(
					temporary: temporary,
					to: destination,
					replacing: task.conflictPolicy == .replace
				)
			} catch {
				throw RemoteFileError.localIO(message: error.localizedDescription)
			}
			advanceProgress(
				id: id,
				to: TransferProgress(
					bytesTransferred: result.bytesTransferred,
					totalBytes: result.bytesTransferred
				)
			)
		} catch {
			let original = remoteFileError(from: error)
			do {
				try await localFiles.remove(temporary)
			} catch {
				throw RemoteFileError.cleanupFailed(
					original: original,
					cleanupMessage: error.localizedDescription
				)
			}
			throw original
		}
	}

	private func prepareRemoteDestination(
		_ requested: String,
		policy: TransferConflictPolicy?,
		client: any RemoteFileClient
	) async throws -> DestinationPreparation<String> {
		guard try await client.stat(requested) != nil else {
			return .ready(requested)
		}
		switch policy {
		case nil:
			return .conflict(requested)
		case .cancel:
			return .cancelled
		case .replace:
			return .ready(requested)
		case .keepBoth:
			var sequence = 2
			while true {
				let candidate = keepBothRemotePath(requested, sequence: sequence)
				if try await client.stat(candidate) == nil {
					return .ready(candidate)
				}
				sequence += 1
			}
		}
	}

	private func apply<Destination>(
		_ preparation: DestinationPreparation<Destination>,
		to id: TaskId
	) -> Destination? {
		guard let index = index(of: id) else { return nil }
		switch preparation {
		case .ready(let destination):
			tasks[index].destination = destinationDescription(destination)
			return destination
		case .conflict(let destination):
			tasks[index].state = .conflict(TransferConflict(
				destination: destinationDescription(destination)
			))
			return nil
		case .cancelled:
			markCancelled(at: index)
			return nil
		}
	}

	private func destinationDescription<Destination>(
		_ destination: Destination
	) -> String {
		if let url = destination as? URL { return url.path }
		return String(describing: destination)
	}

	private func progressHandler(for id: TaskId) -> TransferProgressHandler {
		{ [weak self] progress in
			await self?.advanceProgress(id: id, to: progress)
		}
	}

	private func advanceProgress(id: TaskId, to progress: TransferProgress) {
		guard let index = index(of: id), tasks[index].status == .running else {
			return
		}
		tasks[index].state = .running(
			tasks[index].progress.advancing(to: progress)
		)
	}

	private func markFailed(id: TaskId, failure: RemoteFileError) {
		guard let index = index(of: id) else { return }
		tasks[index].state = .failed(failure, tasks[index].progress)
	}

	private func markCancelled(id: TaskId) {
		guard let index = index(of: id) else { return }
		markCancelled(at: index)
	}

	private func markCancelled(at index: Int) {
		tasks[index].state = .cancelled(tasks[index].progress)
	}

	private func removeFromQueue(_ id: TaskId, hostID: UUID) {
		perHostQueues[hostID]?.removeAll { $0 == id }
	}

	private func index(of id: TaskId) -> Int? {
		tasks.firstIndex { $0.id == id }
	}

	private func keepBothRemotePath(_ path: String, sequence: Int) -> String {
		let value = path as NSString
		let extensionName = value.pathExtension
		let stem = value.deletingPathExtension
		let suffix = " \(sequence)"
		return extensionName.isEmpty
			? stem + suffix
			: stem + suffix + "." + extensionName
	}

	private func remoteFileError(from error: Error) -> RemoteFileError {
		if error is CancellationError { return .cancelled }
		if let failure = error as? RemoteFileError { return failure }
		return .transport(message: String(describing: error))
	}
}

enum DestinationPreparation<Destination: Sendable>: Sendable {
	case ready(Destination)
	case conflict(Destination)
	case cancelled
}

protocol LocalTransferFileCoordinating: Sendable {
	func isDirectory(at url: URL) async throws -> Bool
	func prepareDestination(
		_ requested: URL,
		policy: TransferConflictPolicy?
	) async throws -> DestinationPreparation<URL>
	func temporaryDestination(for destination: URL) async throws -> URL
	func publish(
		temporary: URL,
		to destination: URL,
		replacing: Bool
	) async throws
	func remove(_ url: URL) async throws
}

actor LocalTransferFileCoordinator: LocalTransferFileCoordinating {
	private let fileManager = FileManager.default

	func isDirectory(at url: URL) throws -> Bool {
		try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
	}

	func prepareDestination(
		_ requested: URL,
		policy: TransferConflictPolicy?
	) throws -> DestinationPreparation<URL> {
		guard fileManager.fileExists(atPath: requested.path) else {
			return .ready(requested)
		}
		switch policy {
		case nil:
			return .conflict(requested)
		case .cancel:
			return .cancelled
		case .replace:
			return .ready(requested)
		case .keepBoth:
			return .ready(uniqueDestination(for: requested))
		}
	}

	func temporaryDestination(for destination: URL) throws -> URL {
		let parent = destination.deletingLastPathComponent()
		guard fileManager.fileExists(atPath: parent.path) else {
			throw CocoaError(.fileNoSuchFile)
		}
		return parent.appendingPathComponent(
			".\(destination.lastPathComponent).caterm-partial-\(UUID().uuidString)"
		)
	}

	func publish(
		temporary: URL,
		to destination: URL,
		replacing: Bool
	) throws {
		if replacing, fileManager.fileExists(atPath: destination.path) {
			_ = try fileManager.replaceItemAt(
				destination,
				withItemAt: temporary,
				backupItemName: nil,
				options: []
			)
		} else {
			try fileManager.moveItem(at: temporary, to: destination)
		}
	}

	func remove(_ url: URL) throws {
		guard fileManager.fileExists(atPath: url.path) else { return }
		try fileManager.removeItem(at: url)
	}

	private func uniqueDestination(for requested: URL) -> URL {
		let extensionName = requested.pathExtension
		let stem = requested.deletingPathExtension().lastPathComponent
		let parent = requested.deletingLastPathComponent()
		var sequence = 2
		while true {
			let name = extensionName.isEmpty
				? "\(stem) \(sequence)"
				: "\(stem) \(sequence).\(extensionName)"
			let candidate = parent.appendingPathComponent(name)
			if !fileManager.fileExists(atPath: candidate.path) {
				return candidate
			}
			sequence += 1
		}
	}
}
