import Combine
import Foundation
import SFTPCommandBuilder
import SSHCommandBuilder

public struct TransferLifecycleInterruption: Equatable, Sendable {
	public enum Reason: Equatable, Sendable {
		case background
	}

	public let reason: Reason
	public let transferCount: Int

	public init(reason: Reason, transferCount: Int) {
		self.reason = reason
		self.transferCount = max(0, transferCount)
	}
}

public struct TransferEnqueueContext: Equatable, Sendable {
	public let hostID: UUID
	public let generation: UInt64

	public init(hostID: UUID, generation: UInt64) {
		self.hostID = hostID
		self.generation = generation
	}
}

public struct TransferHostRemovalContext: Equatable, Sendable {
	public let hostID: UUID
	public let revision: UInt64

	public init(hostID: UUID, revision: UInt64) {
		self.hostID = hostID
		self.revision = revision
	}
}

@MainActor
public final class FileTransferStore: ObservableObject {
	public typealias ClientFactory = (SSHHost) -> any RemoteFileClient

	@Published public private(set) var tasks: [TransferTask] = []
	@Published public private(set) var lifecycleInterruption: TransferLifecycleInterruption?

	private let clientForHost: ClientFactory
	private let localFiles: any LocalTransferFileCoordinating
	private let didComplete: @Sendable (TransferTask) async -> Void
	private let didDiscard: @Sendable (TransferTask) async -> Void
	private var perHostQueues: [UUID: [TaskId]] = [:]
	private var perHostBusy: Set<UUID> = []
	private var perHostHost: [UUID: SSHHost] = [:]
	private var runningJobs: [TaskId: Task<Void, Never>] = [:]
	private var transferGeneration: UInt64 = 0
	private var drainingHostIDs: Set<UUID> = []
	private var removedHostIDs: Set<UUID> = []
	private var hostRemovalRevisions: [UUID: UInt64] = [:]
	private var accountResetInProgress = false
	private var admissionSuspended = false
	#if os(macOS)
	private var localAccessGrants: [TaskId: LocalFileAccessGrant] = [:]
	#endif

	/// Creates a transport-independent transfer coordinator.
	public init(
		clientForHost: @escaping ClientFactory,
		didComplete: @escaping @Sendable (TransferTask) async -> Void = { _ in },
		didDiscard: @escaping @Sendable (TransferTask) async -> Void = { _ in }
	) {
		self.clientForHost = clientForHost
		localFiles = LocalTransferFileCoordinator()
		self.didComplete = didComplete
		self.didDiscard = didDiscard
	}

	init(
		clientForHost: @escaping ClientFactory,
		localFiles: any LocalTransferFileCoordinating,
		didComplete: @escaping @Sendable (TransferTask) async -> Void = { _ in },
		didDiscard: @escaping @Sendable (TransferTask) async -> Void = { _ in }
	) {
		self.clientForHost = clientForHost
		self.localFiles = localFiles
		self.didComplete = didComplete
		self.didDiscard = didDiscard
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

	public func captureEnqueueContext(for hostID: UUID) -> TransferEnqueueContext? {
		guard transfersAreAllowed(for: hostID) else { return nil }
		return TransferEnqueueContext(hostID: hostID, generation: transferGeneration)
	}

	public func enqueueUpload(
		localPaths: [URL],
		remoteDir: String,
		host: SSHHost,
		conflictPolicy: TransferConflictPolicy? = nil,
		expectedContext: TransferEnqueueContext? = nil
	) -> [TaskId] {
		guard accepts(expectedContext, for: host.id) else { return [] }
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

	#if os(macOS)
	public func enqueueScopedUpload(
		localFiles: [LocalFileAccessGrant],
		remoteDirectory: String,
		host: SSHHost,
		conflictPolicy: TransferConflictPolicy? = nil,
		expectedContext: TransferEnqueueContext? = nil
	) -> [TaskId] {
		let ids = enqueueUpload(
			localPaths: localFiles.map(\.url),
			remoteDir: remoteDirectory,
			host: host,
			conflictPolicy: conflictPolicy,
			expectedContext: expectedContext
		)
		for (id, grant) in zip(ids, localFiles) {
			localAccessGrants[id] = grant
		}
		return ids
	}
	#endif

	public func enqueueDownload(
		remotePaths: [String],
		localDir: URL,
		host: SSHHost,
		conflictPolicy: TransferConflictPolicy? = nil,
		expectedContext: TransferEnqueueContext? = nil
	) -> [TaskId] {
		guard accepts(expectedContext, for: host.id) else { return [] }
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

	#if os(macOS)
	public func enqueueScopedDownload(
		remotePaths: [String],
		localDirectory: LocalFileAccessGrant,
		host: SSHHost,
		conflictPolicy: TransferConflictPolicy? = nil,
		expectedContext: TransferEnqueueContext? = nil
	) -> [TaskId] {
		let ids = enqueueDownload(
			remotePaths: remotePaths,
			localDir: localDirectory.url,
			host: host,
			conflictPolicy: conflictPolicy,
			expectedContext: expectedContext
		)
		for id in ids {
			localAccessGrants[id] = localDirectory
		}
		return ids
	}
	#endif

	/// Relays remote files through a private local staging directory. The
	/// destination never exposes a partial file under its final name.
	public func enqueueRemoteCopy(
		remotePaths: [String],
		destinationDirectory: String,
		sourceHost: SSHHost,
		destinationHost: SSHHost,
		conflictPolicy: TransferConflictPolicy? = nil,
		expectedContext: TransferEnqueueContext? = nil
	) -> [TaskId] {
		guard accepts(expectedContext, for: destinationHost.id),
			transfersAreAllowed(for: sourceHost.id) else {
			return []
		}
		perHostHost[sourceHost.id] = sourceHost
		perHostHost[destinationHost.id] = destinationHost
		var ids: [TaskId] = []
		for remotePath in remotePaths {
			let destination = (destinationDirectory as NSString)
				.appendingPathComponent(
					(remotePath as NSString).lastPathComponent
				)
			let task = TransferTask(
				id: UUID(),
				kind: .remoteCopy,
				hostId: destinationHost.id,
				sourceHostId: sourceHost.id,
				source: remotePath,
				destination: destination,
				isDirectory: false,
				conflictPolicy: conflictPolicy
			)
			tasks.append(task)
			perHostQueues[destinationHost.id, default: []].append(task.id)
			ids.append(task.id)
		}
		kick(destinationHost.id)
		return ids
	}

	public func client(for host: SSHHost) -> any RemoteFileClient {
		clientForHost(host)
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
			[.failed, .cancelled].contains(tasks[index].status),
			taskHostsAreAvailable(tasks[index]) else {
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
		guard taskHostsAreAvailable(tasks[index]) else { return }
		tasks[index].conflictPolicy = policy
		tasks[index].state = .pending
		perHostQueues[tasks[index].hostId, default: []].append(id)
		kick(tasks[index].hostId)
	}

	/// iOS does not promise indefinite background transport execution. All
	/// unfinished work is cancelled at the background boundary while completed
	/// tasks remain untouched and are never replayed on foreground return.
	@discardableResult
	public func interruptForBackground() -> Int {
		admissionSuspended = true
		advanceGeneration()
		let activeIDs = tasks.compactMap { task in
			[.pending, .running, .conflict].contains(task.status) ? task.id : nil
		}
		guard !activeIDs.isEmpty else { return 0 }
		lifecycleInterruption = TransferLifecycleInterruption(
			reason: .background,
			transferCount: activeIDs.count
		)
		for id in activeIDs { cancel(id) }
		return activeIDs.count
	}

	/// Reconciles state owned by the foreground scene without re-enqueueing any
	/// operation. An orphaned running marker is conservatively cancelled.
	public func reconcileAfterForeground() {
		admissionSuspended = false
		for index in tasks.indices where tasks[index].status == .running {
			if runningJobs[tasks[index].id] == nil {
				markCancelled(at: index)
			}
		}
	}

	public func acknowledgeLifecycleInterruption() {
		lifecycleInterruption = nil
	}

	public func discard(_ id: TaskId) async {
		guard let task = task(id: id),
			[.completed, .failed, .cancelled].contains(task.status) else {
			return
		}
		removeFromQueue(id, hostID: task.hostId)
		tasks.removeAll { $0.id == id }
		#if os(macOS)
		localAccessGrants[id] = nil
		#endif
		await didDiscard(task)
	}

	public func prepareForHostRemoval(
		_ hostID: UUID
	) async -> TransferHostRemovalContext? {
		guard let context = beginHostRemoval(hostID) else { return nil }
		await drainHostRemoval(context)
		return context
	}

	public func beginHostRemoval(
		_ hostID: UUID
	) -> TransferHostRemovalContext? {
		guard !removedHostIDs.contains(hostID) else { return nil }
		let revision: UInt64
		if drainingHostIDs.insert(hostID).inserted {
			advanceGeneration()
			revision = nextHostRemovalRevision(for: hostID)
		} else {
			revision = hostRemovalRevisions[hostID] ?? 0
		}
		cancelTasks {
			$0.hostId == hostID || $0.sourceHostId == hostID
		}
		return TransferHostRemovalContext(hostID: hostID, revision: revision)
	}

	public func drainHostRemoval(_ context: TransferHostRemovalContext) async {
		guard hostRemovalRevisions[context.hostID] == context.revision else { return }
		await waitForRunningJobs {
			$0.hostId == context.hostID
				|| $0.sourceHostId == context.hostID
		}
	}

	public func commitHostRemoval(_ hostID: UUID) async {
		guard let context = await prepareForHostRemoval(hostID) else { return }
		await commitHostRemoval(context)
	}

	public func commitHostRemoval(_ context: TransferHostRemovalContext) async {
		guard hostRemovalRevisions[context.hostID] == context.revision,
			drainingHostIDs.contains(context.hostID) else {
			return
		}
		let discarded = removeCurrentTasks {
			$0.hostId == context.hostID
				|| $0.sourceHostId == context.hostID
		}
		perHostQueues[context.hostID] = nil
		perHostHost[context.hostID] = nil
		removedHostIDs.insert(context.hostID)
		drainingHostIDs.remove(context.hostID)
		for task in discarded {
			await didDiscard(task)
		}
	}

	public func abortHostRemoval(_ context: TransferHostRemovalContext) {
		guard hostRemovalRevisions[context.hostID] == context.revision else { return }
		drainingHostIDs.remove(context.hostID)
	}

	public func restoreHost(_ hostID: UUID) {
		_ = nextHostRemovalRevision(for: hostID)
		drainingHostIDs.remove(hostID)
		removedHostIDs.remove(hostID)
	}

	public func discardTasks(forHost hostID: UUID) async {
		await commitHostRemoval(hostID)
	}

	public func resetForAccountChange() async {
		guard !accountResetInProgress else { return }
		accountResetInProgress = true
		advanceGeneration()
		cancelTasks { _ in true }
		await waitForRunningJobs { _ in true }
		let discarded = removeCurrentTasks { _ in true }
		perHostQueues.removeAll()
		perHostHost.removeAll()
		drainingHostIDs.removeAll()
		removedHostIDs.removeAll()
		lifecycleInterruption = nil
		accountResetInProgress = false
		for task in discarded {
			await didDiscard(task)
		}
	}

	public func waitIdle() async throws {
		while !perHostBusy.isEmpty || perHostQueues.values.contains(where: {
			!$0.isEmpty
		}) {
			try await Task.sleep(for: .milliseconds(5))
		}
	}

	private func kick(_ hostID: UUID) {
		guard transfersAreAllowed(for: hostID),
		      !perHostBusy.contains(hostID),
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

	private func cancelTasks(
		where shouldDiscard: (TransferTask) -> Bool
	) {
		for task in tasks where shouldDiscard(task)
			&& [.pending, .running, .conflict].contains(task.status) {
			cancel(task.id)
		}
	}

	private func waitForRunningJobs(
		where shouldWait: (TransferTask) -> Bool
	) async {
		let matching = tasks.filter(shouldWait)
		for task in matching {
			await runningJobs[task.id]?.value
		}
	}

	private func removeCurrentTasks(
		where shouldDiscard: (TransferTask) -> Bool
	) -> [TransferTask] {
		let matching = tasks.filter(shouldDiscard)
		let ids = Set(matching.map(\.id))
		tasks.removeAll { ids.contains($0.id) }
		#if os(macOS)
		for id in ids {
			localAccessGrants[id] = nil
		}
		#endif
		return matching
	}

	private func accepts(
		_ context: TransferEnqueueContext?,
		for hostID: UUID
	) -> Bool {
		guard transfersAreAllowed(for: hostID) else { return false }
		guard let context else { return true }
		return context.hostID == hostID && context.generation == transferGeneration
	}

	private func transfersAreAllowed(for hostID: UUID) -> Bool {
		!admissionSuspended
			&& !accountResetInProgress
			&& !drainingHostIDs.contains(hostID)
			&& !removedHostIDs.contains(hostID)
	}

	private func taskHostsAreAvailable(_ task: TransferTask) -> Bool {
		guard transfersAreAllowed(for: task.hostId) else { return false }
		guard let sourceHostID = task.sourceHostId else { return true }
		return transfersAreAllowed(for: sourceHostID)
	}

	private func advanceGeneration() {
		transferGeneration &+= 1
	}

	private func nextHostRemovalRevision(for hostID: UUID) -> UInt64 {
		let revision = (hostRemovalRevisions[hostID] ?? 0) &+ 1
		hostRemovalRevisions[hostID] = revision
		return revision
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
			case .remoteCopy:
				guard let sourceHostID = tasks[index].sourceHostId,
					let sourceHost = perHostHost[sourceHostID] else {
					throw RemoteFileError.invalidResponse(
						message: "Missing source Host registration"
					)
				}
				try await executeRemoteCopy(
					id: id,
					sourceClient: clientForHost(sourceHost),
					destinationClient: client
				)
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
		#if os(macOS)
		if let grant = localAccessGrants[id] {
			try await grant.withAccess { [self] _ in
				try await executeUploadWithAvailableSource(
					id: id,
					client: client
				)
			}
			return
		}
		#endif
		try await executeUploadWithAvailableSource(id: id, client: client)
	}

	private func executeUploadWithAvailableSource(
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
		#if os(macOS)
		if let grant = localAccessGrants[id] {
			try await grant.withAccess { [self] _ in
				try await executeDownloadWithAvailableDestination(
					id: id,
					client: client
				)
			}
			return
		}
		#endif
		try await executeDownloadWithAvailableDestination(
			id: id,
			client: client
		)
	}

	private func executeDownloadWithAvailableDestination(
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

	private func executeRemoteCopy(
		id: TaskId,
		sourceClient: any RemoteFileClient,
		destinationClient: any RemoteFileClient
	) async throws {
		guard let task = task(id: id) else { return }
		guard let sourceEntry = try await sourceClient.stat(task.source) else {
			throw RemoteFileError.notFound(path: task.source)
		}
		guard let index = index(of: id) else { return }
		tasks[index].isDirectory = sourceEntry.isDirectory
		let preparation = try await prepareRemoteDestination(
			task.destination,
			policy: task.conflictPolicy,
			client: destinationClient
		)
		guard let destination = apply(preparation, to: id) else { return }

		let stagingDirectory: URL
		do {
			stagingDirectory = try await localFiles
				.createPrivateStagingDirectory()
		} catch {
			throw RemoteFileError.localIO(
				message: error.localizedDescription
			)
		}
		let stagedFile = stagingDirectory.appendingPathComponent(
			(task.source as NSString).lastPathComponent
		)
		let temporaryRemotePath = remoteTemporaryPath(for: destination)
		var uploadedTemporary = false
		do {
			let sourceSize = sourceEntry.size
			let download = try await sourceClient.download(
				remotePath: task.source,
				localURL: stagedFile,
				isDirectory: sourceEntry.isDirectory,
				resume: false,
				progress: relayProgressHandler(
					for: id,
					phase: .download,
					sourceSize: sourceSize
				)
			)
			try Task.checkCancellation()
			let transferSize = sourceSize ?? download.bytesTransferred
			_ = try await destinationClient.upload(
				localURL: stagedFile,
				remotePath: temporaryRemotePath,
				isDirectory: sourceEntry.isDirectory,
				resume: false,
				replaceExisting: false,
				progress: relayProgressHandler(
					for: id,
					phase: .upload,
					sourceSize: transferSize
				)
			)
			uploadedTemporary = true
			try Task.checkCancellation()
			try await destinationClient.rename(
				from: temporaryRemotePath,
				to: destination
			)
			uploadedTemporary = false
			advanceProgress(
				id: id,
				to: TransferProgress(
					bytesTransferred: transferSize * 2,
					totalBytes: transferSize * 2
				)
			)
			try await localFiles.remove(stagingDirectory)
		} catch {
			let original = remoteFileError(from: error)
			var cleanupMessages: [String] = []
			if uploadedTemporary {
				do {
					try await destinationClient.delete(
						temporaryRemotePath,
						isDirectory: sourceEntry.isDirectory
					)
				} catch {
					cleanupMessages.append(error.localizedDescription)
				}
			}
			do {
				try await localFiles.remove(stagingDirectory)
			} catch {
				cleanupMessages.append(error.localizedDescription)
			}
			guard cleanupMessages.isEmpty else {
				throw RemoteFileError.cleanupFailed(
					original: original,
					cleanupMessage: cleanupMessages.joined(
						separator: "; "
					)
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

	private enum RelayProgressPhase {
		case download
		case upload
	}

	private func relayProgressHandler(
		for id: TaskId,
		phase: RelayProgressPhase,
		sourceSize: Int64?
	) -> TransferProgressHandler {
		{ [weak self] progress in
			let size = sourceSize ?? progress.totalBytes
			let total = size.map { $0 * 2 }
			let completedSource = phase == .upload ? (size ?? 0) : 0
			await self?.advanceProgress(
				id: id,
				to: TransferProgress(
					bytesTransferred:
						completedSource + progress.bytesTransferred,
					totalBytes: total
				)
			)
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

	private func remoteTemporaryPath(for destination: String) -> String {
		let value = destination as NSString
		let parent = value.deletingLastPathComponent
		let filename = value.lastPathComponent
		let temporaryName =
			".\(filename).caterm-partial-\(UUID().uuidString.lowercased())"
		return (parent as NSString).appendingPathComponent(temporaryName)
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
	func createPrivateStagingDirectory() async throws -> URL
}

extension LocalTransferFileCoordinating {
	func createPrivateStagingDirectory() async throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent(
				"caterm-remote-relay-\(UUID().uuidString.lowercased())",
				isDirectory: true
			)
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		return directory
	}
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
