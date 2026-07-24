import AppKit
import CryptoKit
import FileTransferStore
import Foundation
import SSHCommandBuilder

struct RemoteFileRevision: Equatable, Sendable {
	let size: Int64?
	let modifiedAt: Date?
	let contentDigest: Data?

	init(entry: RemoteEntry?, contentDigest: Data? = nil) {
		size = entry?.size
		modifiedAt = entry?.mtime
		self.contentDigest = contentDigest
	}

	func comparison(with other: RemoteFileRevision) -> Comparison {
		if let contentDigest, let otherDigest = other.contentDigest {
			return contentDigest == otherDigest ? .unchanged : .changed
		}
		if let size, let otherSize = other.size, size != otherSize {
			return .changed
		}
		if let modifiedAt, let otherModifiedAt = other.modifiedAt,
			modifiedAt != otherModifiedAt {
			return .changed
		}
		if size != nil, other.size != nil,
			modifiedAt != nil, other.modifiedAt != nil {
			return .unchanged
		}
		return .unverifiable
	}

	func withContentDigest(_ digest: Data) -> RemoteFileRevision {
		RemoteFileRevision(
			size: size,
			modifiedAt: modifiedAt,
			contentDigest: digest
		)
	}

	private init(
		size: Int64?,
		modifiedAt: Date?,
		contentDigest: Data?
	) {
		self.size = size
		self.modifiedAt = modifiedAt
		self.contentDigest = contentDigest
	}

	enum Comparison: Equatable, Sendable {
		case unchanged
		case changed
		case unverifiable
	}
}

struct RemoteEditConflictMetadata: Equatable, Sendable {
	let comparison: RemoteFileRevision.Comparison
	let baseline: RemoteFileRevision
	let current: RemoteFileRevision
}

struct RemoteExternalEditSession: Identifiable, Equatable, Sendable {
	enum FailureOperation: Equatable, Sendable {
		case prepare(editorURL: URL)
		case refresh
		case review
		case upload(replacingRemote: Bool)
		case downloadNewer
		case cleanup
	}

	enum State: Equatable, Sendable {
		case preparing
		case watching(uploadedAt: Date?)
		case modified
		case reviewing
		case awaitingUploadConfirmation
		case conflict(RemoteEditConflictMetadata)
		case uploading
		case downloadingNewer
		case failed(message: String, retry: FailureOperation?)
	}

	let id: UUID
	let side: SFTPTaskSide
	let hostID: UUID
	let remotePath: String
	let stagedURL: URL
	let editorName: String
	var baselineRevision: RemoteFileRevision
	var baselineDigest: Data
	var state: State

	var fileName: String {
		(remotePath as NSString).lastPathComponent
	}
}

enum RemoteExternalEditorError: LocalizedError {
	case missingRemoteFile(String)
	case fileChangedDuringDownload(String)
	case editorLaunchFailed(String)

	var errorDescription: String? {
		switch self {
		case .missingRemoteFile(let path):
			"The remote file no longer exists: \(path)"
		case .fileChangedDuringDownload(let path):
			"The remote file changed while it was being staged: \(path)"
		case .editorLaunchFailed(let editor):
			"Caterm could not open the file in \(editor)."
		}
	}
}

@MainActor
final class RemoteExternalEditorRegistry {
	static let shared = RemoteExternalEditorRegistry()

	private final class WeakCoordinator {
		weak var value: RemoteExternalEditorCoordinator?

		init(_ value: RemoteExternalEditorCoordinator) {
			self.value = value
		}
	}

	private var coordinators: [ObjectIdentifier: WeakCoordinator] = [:]
	private var startupCleanupTasks: [URL: Task<Void, Never>] = [:]

	var hasActiveSessions: Bool {
		liveCoordinators.contains { !$0.sessions.isEmpty }
	}

	func register(_ coordinator: RemoteExternalEditorCoordinator) {
		coordinators[ObjectIdentifier(coordinator)] = WeakCoordinator(coordinator)
	}

	func startupCleanupTask(for rootURL: URL) -> Task<Void, Never> {
		if let task = startupCleanupTasks[rootURL] {
			return task
		}
		let task = Task.detached {
			guard FileManager.default.fileExists(atPath: rootURL.path) else {
				return
			}
			do {
				try FileManager.default.removeItem(at: rootURL)
			} catch {
				NSLog(
					"[RemoteExternalEditor] Startup cleanup failed: \(error.localizedDescription)"
				)
			}
		}
		startupCleanupTasks[rootURL] = task
		return task
	}

	func closeAll() async -> Bool {
		var cleanedAll = true
		for coordinator in liveCoordinators {
			if await coordinator.closeAll() == false {
				cleanedAll = false
			}
		}
		return cleanedAll
	}

	private var liveCoordinators: [RemoteExternalEditorCoordinator] {
		coordinators = coordinators.filter { $0.value.value != nil }
		return coordinators.values.compactMap(\.value)
	}
}

@MainActor
final class RemoteExternalEditorCoordinator: ObservableObject {
	typealias EditorOpener = @MainActor @Sendable (
		_ fileURL: URL,
		_ editorURL: URL
	) async throws -> Int32?

	@Published private(set) var sessions: [SFTPTaskSide: RemoteExternalEditSession] = [:]

	private let rootURL: URL
	private let openEditor: EditorOpener
	private let startupCleanupTask: Task<Void, Never>
	private var hosts: [SFTPTaskSide: SSHHost] = [:]
	private var transferStores: [SFTPTaskSide: FileTransferStore] = [:]
	private var activeTaskIDs: [SFTPTaskSide: TaskId] = [:]
	private var watchers: [SFTPTaskSide: DraftWatcher] = [:]
	private var watcherDebounceTasks: [SFTPTaskSide: Task<Void, Never>] = [:]
	private var editorTerminationObservers: [SFTPTaskSide: NSObjectProtocol] = [:]

	init(
		rootURL: URL = FileManager.default.temporaryDirectory
			.appendingPathComponent(
				"Caterm-External-Edits",
				isDirectory: true
			),
		openEditor: EditorOpener? = nil
	) {
		self.rootURL = rootURL
		startupCleanupTask = RemoteExternalEditorRegistry.shared
			.startupCleanupTask(for: rootURL)
		self.openEditor = openEditor ?? { fileURL, editorURL in
			try await RemoteExternalEditorCoordinator.openWithWorkspace(
				fileURL: fileURL,
				editorURL: editorURL
			)
		}
		RemoteExternalEditorRegistry.shared.register(self)
	}

	func session(for side: SFTPTaskSide) -> RemoteExternalEditSession? {
		sessions[side]
	}

	func start(
		side: SFTPTaskSide,
		remotePath: String,
		editorURL: URL,
		host: SSHHost,
		transferStore: FileTransferStore
	) async {
		await startupCleanupTask.value
		guard sessions[side] == nil else { return }
		let id = UUID()
		let directoryURL = rootURL.appendingPathComponent(
			id.uuidString,
			isDirectory: true
		)
		let stagedURL = directoryURL.appendingPathComponent(
			(remotePath as NSString).lastPathComponent,
			isDirectory: false
		)
		let editorName = editorURL.deletingPathExtension().lastPathComponent
		sessions[side] = RemoteExternalEditSession(
			id: id,
			side: side,
			hostID: host.id,
			remotePath: remotePath,
			stagedURL: stagedURL,
			editorName: editorName,
			baselineRevision: RemoteFileRevision(entry: nil),
			baselineDigest: Data(),
			state: .preparing
		)
		hosts[side] = host
		transferStores[side] = transferStore
		let client = transferStore.client(for: host)

		do {
			try await createPrivateDirectory(directoryURL)
			let before = try await remoteRevision(
				client: client,
				path: remotePath
			)
			try await runStagingDownload(
				side: side,
				sessionID: id,
				remotePath: remotePath,
				directoryURL: directoryURL,
				host: host,
				transferStore: transferStore
			)
			try await setPrivateFilePermissions(at: stagedURL)
			let after = try await remoteRevision(
				client: client,
				path: remotePath
			)
			if before.comparison(with: after) == .changed {
				throw RemoteExternalEditorError.fileChangedDuringDownload(
					remotePath
				)
			}
			let digest = try await fileDigest(at: stagedURL)
			guard sessions[side]?.id == id else { return }
			sessions[side]?.baselineRevision = after.withContentDigest(
				digest
			)
			sessions[side]?.baselineDigest = digest
			try installWatcher(
				side: side,
				directoryURL: directoryURL,
				fileURL: stagedURL
			)
			do {
				let processIdentifier = try await openEditor(
					stagedURL,
					editorURL
				)
				if let processIdentifier {
					installEditorTerminationObserver(
						side: side,
						processIdentifier: processIdentifier
					)
				}
			} catch {
				throw RemoteExternalEditorError.editorLaunchFailed(
					editorName
				)
			}
			guard sessions[side]?.id == id else { return }
			sessions[side]?.state = .watching(uploadedAt: nil)
		} catch {
			fail(
				side: side,
				id: id,
				error: error,
				retry: .prepare(editorURL: editorURL)
			)
		}
	}

	func refreshLocalModification(side: SFTPTaskSide) async {
		guard let session = sessions[side],
			session.state != .preparing,
			session.state != .uploading,
			session.state != .downloadingNewer else {
			return
		}
		do {
			let digest = try await fileDigest(at: session.stagedURL)
			guard sessions[side]?.id == session.id else { return }
			if digest != session.baselineDigest {
				sessions[side]?.state = .modified
			} else if case .modified = session.state {
				sessions[side]?.state = .watching(uploadedAt: nil)
			}
		} catch {
			fail(
				side: side,
				id: session.id,
				error: error,
				retry: .refresh
			)
		}
	}

	func reviewUpload(side: SFTPTaskSide) async {
		guard let session = sessions[side],
			let host = hosts[side],
			let transferStore = transferStores[side] else {
			return
		}
		sessions[side]?.state = .reviewing
		do {
			let current = try await verifiedCurrentRevision(
				for: session,
				side: side,
				host: host,
				transferStore: transferStore
			)
			guard sessions[side]?.id == session.id else { return }
			let comparison = session.baselineRevision.comparison(
				with: current
			)
			switch comparison {
			case .unchanged:
				sessions[side]?.state = .awaitingUploadConfirmation
			case .changed, .unverifiable:
				sessions[side]?.state = .conflict(
					RemoteEditConflictMetadata(
						comparison: comparison,
						baseline: session.baselineRevision,
						current: current
					)
				)
			}
		} catch {
			fail(
				side: side,
				id: session.id,
				error: error,
				retry: .review
			)
		}
	}

	func upload(side: SFTPTaskSide, replacingRemote: Bool) async {
		guard let session = sessions[side],
			let host = hosts[side],
			let transferStore = transferStores[side] else {
			return
		}
		let client = transferStore.client(for: host)
		sessions[side]?.state = .uploading
		let uploadSnapshot = session.stagedURL
			.deletingLastPathComponent()
			.appendingPathComponent(
				".\(session.fileName).caterm-upload-\(UUID().uuidString)"
			)
		defer {
			Task.detached {
				do {
					try await Self.removeStagingItem(uploadSnapshot)
				} catch {
					NSLog(
						"[RemoteExternalEditor] Upload snapshot cleanup failed: \(error.localizedDescription)"
					)
				}
			}
		}
		var queuedTaskID: TaskId?
		do {
			if !replacingRemote {
				let current = try await verifiedCurrentRevision(
					for: session,
					side: side,
					host: host,
					transferStore: transferStore
				)
				let comparison = session.baselineRevision.comparison(
					with: current
				)
				guard comparison == .unchanged else {
					guard sessions[side]?.id == session.id else { return }
					sessions[side]?.state = .conflict(
						RemoteEditConflictMetadata(
							comparison: comparison,
							baseline: session.baselineRevision,
							current: current
						)
					)
					return
				}
			}
			try await makePrivateSnapshot(
				from: session.stagedURL,
				to: uploadSnapshot
			)
			let uploadedDigest = try await fileDigest(at: uploadSnapshot)
			let preflight: FileTransferStore.AtomicUploadPreflight?
			if replacingRemote {
				preflight = nil
			} else {
				let remotePath = session.remotePath
				let expectedDigest = session.baselineDigest
				preflight = { client in
					try await Self.remoteContentMatches(
						client: client,
						remotePath: remotePath,
						expectedDigest: expectedDigest
					)
				}
			}
			guard let taskID = transferStore.enqueueAtomicUpload(
				localFile: uploadSnapshot,
				remotePath: session.remotePath,
				host: host,
				conflictPolicy: .replace,
				prePublishValidation: preflight
			) else {
				throw RemoteFileError.sessionUnavailable
			}
			queuedTaskID = taskID
			try await waitForTransfer(
				taskID,
				side: side,
				sessionID: session.id,
				transferStore: transferStore
			)
			let revision = try await remoteRevision(
				client: client,
				path: session.remotePath
			)
			let currentDigest = try await fileDigest(at: session.stagedURL)
			guard sessions[side]?.id == session.id else { return }
			sessions[side]?.baselineRevision = revision.withContentDigest(
				uploadedDigest
			)
			sessions[side]?.baselineDigest = uploadedDigest
			sessions[side]?.state = currentDigest == uploadedDigest
				? .watching(uploadedAt: Date())
				: .modified
		} catch RemoteFileError.conflict {
			if let queuedTaskID {
				transferStore.cancel(queuedTaskID)
				await transferStore.discard(queuedTaskID)
			}
			await reviewUpload(side: side)
		} catch {
			fail(
				side: side,
				id: session.id,
				error: error,
				retry: .upload(replacingRemote: replacingRemote)
			)
		}
	}

	func downloadNewer(side: SFTPTaskSide) async {
		guard let session = sessions[side],
			let host = hosts[side],
			let transferStore = transferStores[side] else {
			return
		}
		let client = transferStore.client(for: host)
		sessions[side]?.state = .downloadingNewer
		do {
			guard let taskID = transferStore.enqueueDownload(
				remotePaths: [session.remotePath],
				localDir: session.stagedURL.deletingLastPathComponent(),
				host: host,
				conflictPolicy: .replace
			).first else {
				throw RemoteFileError.sessionUnavailable
			}
			try await waitForTransfer(
				taskID,
				side: side,
				sessionID: session.id,
				transferStore: transferStore
			)
			try await setPrivateFilePermissions(at: session.stagedURL)
			let revision = try await remoteRevision(
				client: client,
				path: session.remotePath
			)
			let digest = try await fileDigest(at: session.stagedURL)
			guard sessions[side]?.id == session.id else { return }
			sessions[side]?.baselineRevision = revision.withContentDigest(
				digest
			)
			sessions[side]?.baselineDigest = digest
			sessions[side]?.state = .watching(uploadedAt: nil)
		} catch {
			fail(
				side: side,
				id: session.id,
				error: error,
				retry: .downloadNewer
			)
		}
	}

	func keepEditing(side: SFTPTaskSide) {
		guard sessions[side] != nil else { return }
		sessions[side]?.state = .modified
	}

	func retry(side: SFTPTaskSide) async {
		guard let session = sessions[side],
			case .failed(_, let operation) = session.state,
			let operation else {
			return
		}
		switch operation {
		case .prepare(let editorURL):
			guard let host = hosts[side],
				let transferStore = transferStores[side],
				await close(side: side) else {
				return
			}
			await start(
				side: side,
				remotePath: session.remotePath,
				editorURL: editorURL,
				host: host,
				transferStore: transferStore
			)
		case .refresh:
			sessions[side]?.state = .modified
			await refreshLocalModification(side: side)
		case .review:
			await reviewUpload(side: side)
		case .upload(let replacingRemote):
			await upload(
				side: side,
				replacingRemote: replacingRemote
			)
		case .downloadNewer:
			await downloadNewer(side: side)
		case .cleanup:
			_ = await close(side: side)
		}
	}

	@discardableResult
	func close(side: SFTPTaskSide) async -> Bool {
		if let taskID = activeTaskIDs.removeValue(forKey: side),
			let transferStore = transferStores[side] {
			transferStore.cancel(taskID)
			do {
				_ = try await transferStore.waitForTerminalTask(taskID)
			} catch is CancellationError {
				return false
			} catch {
				NSLog(
					"[RemoteExternalEditor] Transfer cancellation wait failed: \(error.localizedDescription)"
				)
			}
			await transferStore.discard(taskID)
		}
		watchers[side]?.cancel()
		watchers[side] = nil
		watcherDebounceTasks[side]?.cancel()
		watcherDebounceTasks[side] = nil
		if let observer = editorTerminationObservers.removeValue(
			forKey: side
		) {
			NSWorkspace.shared.notificationCenter.removeObserver(observer)
		}
		guard let session = sessions.removeValue(forKey: side) else {
			hosts[side] = nil
			transferStores[side] = nil
			return true
		}
		let directoryURL = session.stagedURL.deletingLastPathComponent()
		do {
			try await Self.removeStagingItem(directoryURL)
			hosts[side] = nil
			transferStores[side] = nil
			return true
		} catch {
			var retained = session
			retained.state = .failed(
				message:
					"The private draft could not be deleted: \(error.localizedDescription)",
				retry: .cleanup
			)
			sessions[side] = retained
			return false
		}
	}

	@discardableResult
	func closeAll() async -> Bool {
		var cleanedAll = true
		for side in Array(sessions.keys) {
			if await close(side: side) == false {
				cleanedAll = false
			}
		}
		return cleanedAll
	}

	private func installWatcher(
		side: SFTPTaskSide,
		directoryURL: URL,
		fileURL: URL
	) throws {
		let watcher = try DraftWatcher(
			directoryURL: directoryURL,
			fileURL: fileURL
		) {
			[weak self] in
			Task { @MainActor in
				self?.scheduleModificationRefresh(side: side)
			}
		}
		watchers[side]?.cancel()
		watchers[side] = watcher
	}

	private func scheduleModificationRefresh(side: SFTPTaskSide) {
		watcherDebounceTasks[side]?.cancel()
		watcherDebounceTasks[side] = Task { [weak self] in
			do {
				try await Task.sleep(for: .milliseconds(200))
				guard !Task.isCancelled else { return }
				guard let self,
					let session = sessions[side] else {
					return
				}
				await refreshLocalModification(side: side)
				guard sessions[side]?.id == session.id else { return }
				do {
					try installWatcher(
						side: side,
						directoryURL:
							session.stagedURL.deletingLastPathComponent(),
						fileURL: session.stagedURL
					)
				} catch {
					fail(
						side: side,
						id: session.id,
						error: error,
						retry: .refresh
					)
				}
			} catch {
				return
			}
		}
	}

	private func installEditorTerminationObserver(
		side: SFTPTaskSide,
		processIdentifier: Int32
	) {
		let observer = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.didTerminateApplicationNotification,
			object: nil,
			queue: .main
		) { [weak self] notification in
			guard let application =
				notification.userInfo?[
					NSWorkspace.applicationUserInfoKey
				] as? NSRunningApplication,
				application.processIdentifier == processIdentifier else {
				return
			}
			Task { @MainActor in
				await self?.handleEditorTermination(side: side)
			}
		}
		editorTerminationObservers[side] = observer
	}

	private func handleEditorTermination(side: SFTPTaskSide) async {
		do {
			try await Task.sleep(for: .milliseconds(300))
		} catch {
			return
		}
		await refreshLocalModification(side: side)
		guard let state = sessions[side]?.state else { return }
		switch state {
		case .watching:
			_ = await close(side: side)
		case .preparing, .modified, .reviewing,
			.awaitingUploadConfirmation, .conflict,
			.uploading, .downloadingNewer, .failed:
			return
		}
	}

	private func remoteRevision(
		client: any RemoteFileClient,
		path: String
	) async throws -> RemoteFileRevision {
		let entry = try await client.stat(path)
		guard entry != nil else {
			throw RemoteExternalEditorError.missingRemoteFile(path)
		}
		return RemoteFileRevision(entry: entry)
	}

	private func verifiedCurrentRevision(
		for session: RemoteExternalEditSession,
		side: SFTPTaskSide,
		host: SSHHost,
		transferStore: FileTransferStore
	) async throws -> RemoteFileRevision {
		let client = transferStore.client(for: host)
		let metadata = try await remoteRevision(
			client: client,
			path: session.remotePath
		)
		guard session.baselineRevision.comparison(with: metadata)
			== .unverifiable else {
			return metadata
		}

		let verificationDirectory = rootURL.appendingPathComponent(
			"verify-\(UUID().uuidString)",
			isDirectory: true
		)
		defer {
			Task.detached {
				do {
					try await Self.removeStagingItem(verificationDirectory)
				} catch {
					NSLog(
						"[RemoteExternalEditor] Verification cleanup failed: \(error.localizedDescription)"
					)
				}
			}
		}
		try await createPrivateDirectory(verificationDirectory)
		guard let taskID = transferStore.enqueueDownload(
			remotePaths: [session.remotePath],
			localDir: verificationDirectory,
			host: host,
			conflictPolicy: .replace
		).first else {
			throw RemoteFileError.sessionUnavailable
		}
		try await waitForTransfer(
			taskID,
			side: side,
			sessionID: session.id,
			transferStore: transferStore
		)
		let verificationFile = verificationDirectory.appendingPathComponent(
			session.fileName,
			isDirectory: false
		)
		let digest = try await fileDigest(at: verificationFile)
		let after = try await remoteRevision(
			client: client,
			path: session.remotePath
		)
		return after.withContentDigest(digest)
	}

	private func createPrivateDirectory(_ directoryURL: URL) async throws {
		try await Task.detached {
			try FileManager.default.createDirectory(
				at: directoryURL,
				withIntermediateDirectories: true,
				attributes: [.posixPermissions: 0o700]
			)
		}.value
	}

	private func setPrivateFilePermissions(at url: URL) async throws {
		try await Task.detached {
			try FileManager.default.setAttributes(
				[.posixPermissions: 0o600],
				ofItemAtPath: url.path
			)
		}.value
	}

	private func makePrivateSnapshot(
		from source: URL,
		to destination: URL
	) async throws {
		try await Task.detached {
			try FileManager.default.copyItem(
				at: source,
				to: destination
			)
			try FileManager.default.setAttributes(
				[.posixPermissions: 0o600],
				ofItemAtPath: destination.path
			)
		}.value
	}

	private func runStagingDownload(
		side: SFTPTaskSide,
		sessionID: UUID,
		remotePath: String,
		directoryURL: URL,
		host: SSHHost,
		transferStore: FileTransferStore
	) async throws {
		guard let taskID = transferStore.enqueueDownload(
			remotePaths: [remotePath],
			localDir: directoryURL,
			host: host,
			conflictPolicy: .replace
		).first else {
			throw RemoteFileError.sessionUnavailable
		}
		try await waitForTransfer(
			taskID,
			side: side,
			sessionID: sessionID,
			transferStore: transferStore
		)
	}

	private func waitForTransfer(
		_ taskID: TaskId,
		side: SFTPTaskSide,
		sessionID: UUID,
		transferStore: FileTransferStore
	) async throws {
		activeTaskIDs[side] = taskID
		defer {
			if activeTaskIDs[side] == taskID {
				activeTaskIDs[side] = nil
			}
		}
		let transfer = try await transferStore.waitForTerminalTask(taskID)
		guard sessions[side]?.id == sessionID else {
			throw RemoteFileError.cancelled
		}
		guard let transfer else {
			throw RemoteFileError.staleOperation
		}
		switch transfer.state {
		case .completed:
			return
		case .failed(let failure, _):
			await transferStore.discard(taskID)
			throw failure
		case .cancelled:
			await transferStore.discard(taskID)
			throw RemoteFileError.cancelled
		case .conflict(let conflict):
			transferStore.cancel(taskID)
			await transferStore.discard(taskID)
			throw RemoteFileError.conflict(path: conflict.destination)
		case .pending, .running:
			throw RemoteFileError.staleOperation
		}
	}

	private func fileDigest(at url: URL) async throws -> Data {
		try await Task.detached(priority: .utility) {
			let data = try Data(contentsOf: url, options: [.mappedIfSafe])
			return Data(SHA256.hash(data: data))
		}.value
	}

	nonisolated private static func remoteContentMatches(
		client: any RemoteFileClient,
		remotePath: String,
		expectedDigest: Data
	) async throws -> Bool {
		guard try await client.stat(remotePath) != nil else { return false }
		let directoryURL = FileManager.default.temporaryDirectory
			.appendingPathComponent(
				"caterm-edit-preflight-\(UUID().uuidString)",
				isDirectory: true
			)
		let fileURL = directoryURL.appendingPathComponent(
			(remotePath as NSString).lastPathComponent,
			isDirectory: false
		)
		try await Task.detached {
			try FileManager.default.createDirectory(
				at: directoryURL,
				withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700]
			)
		}.value
		do {
			_ = try await client.download(
				remotePath: remotePath,
				localURL: fileURL,
				isDirectory: false,
				resume: false,
				progress: { _ in }
			)
			let digest = try await Task.detached {
				let data = try Data(
					contentsOf: fileURL,
					options: [.mappedIfSafe]
				)
				return Data(SHA256.hash(data: data))
			}.value
			try await removeStagingItem(directoryURL)
			return digest == expectedDigest
		} catch {
			let original = error
			do {
				try await removeStagingItem(directoryURL)
			} catch {
				let remoteFailure = original as? RemoteFileError
					?? .transport(message: original.localizedDescription)
				throw RemoteFileError.cleanupFailed(
					original: remoteFailure,
					cleanupMessage: error.localizedDescription
				)
			}
			throw original
		}
	}

	nonisolated private static func removeStagingItem(
		_ url: URL
	) async throws {
		try await Task.detached {
			guard FileManager.default.fileExists(atPath: url.path) else {
				return
			}
			try FileManager.default.removeItem(at: url)
		}.value
	}

	private func fail(
		side: SFTPTaskSide,
		id: UUID,
		error: Error,
		retry: RemoteExternalEditSession.FailureOperation?
	) {
		guard sessions[side]?.id == id else { return }
		sessions[side]?.state = .failed(
			message: error.localizedDescription,
			retry: retry
		)
	}

	private static func openWithWorkspace(
		fileURL: URL,
		editorURL: URL
	) async throws -> Int32? {
		try await withCheckedThrowingContinuation {
			(continuation: CheckedContinuation<Int32?, Error>) in
			let configuration = NSWorkspace.OpenConfiguration()
			NSWorkspace.shared.open(
				[fileURL],
				withApplicationAt: editorURL,
				configuration: configuration
			) { application, error in
				if let error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume(
						returning: application?.processIdentifier
					)
				}
			}
		}
	}
}

private final class DraftWatcher: @unchecked Sendable {
	private let directoryWatcher: FileSystemWatcher
	private let fileWatcher: FileSystemWatcher

	init(
		directoryURL: URL,
		fileURL: URL,
		onChange: @escaping @Sendable () -> Void
	) throws {
		let directoryWatcher = try FileSystemWatcher(
			url: directoryURL,
			eventMask: [.write, .rename, .delete, .attrib, .revoke],
			onChange: onChange
		)
		do {
			let fileWatcher = try FileSystemWatcher(
				url: fileURL,
				eventMask: [
					.write, .extend, .rename, .delete, .attrib, .revoke,
				],
				onChange: onChange
			)
			self.directoryWatcher = directoryWatcher
			self.fileWatcher = fileWatcher
		} catch {
			directoryWatcher.cancel()
			throw error
		}
	}

	func cancel() {
		directoryWatcher.cancel()
		fileWatcher.cancel()
	}
}

private final class FileSystemWatcher: @unchecked Sendable {
	private let source: DispatchSourceFileSystemObject
	private let descriptor: Int32

	init(
		url: URL,
		eventMask: DispatchSource.FileSystemEvent,
		onChange: @escaping @Sendable () -> Void
	) throws {
		descriptor = open(url.path, O_EVTONLY)
		guard descriptor >= 0 else {
			let errorNumber = errno
			throw FileSystemWatcherError.openFailed(
				path: url.path,
				errorNumber: errorNumber,
				reason: String(cString: strerror(errorNumber))
			)
		}
		source = DispatchSource.makeFileSystemObjectSource(
			fileDescriptor: descriptor,
			eventMask: eventMask,
			queue: .global(qos: .utility)
		)
		source.setEventHandler(handler: onChange)
		source.setCancelHandler { [descriptor] in
			Darwin.close(descriptor)
		}
		source.resume()
	}

	func cancel() {
		source.cancel()
	}

	deinit {
		source.cancel()
	}
}

private enum FileSystemWatcherError: LocalizedError {
	case openFailed(path: String, errorNumber: Int32, reason: String)

	var errorDescription: String? {
		switch self {
		case .openFailed(let path, let errorNumber, let reason):
			"Could not monitor \(path) (errno \(errorNumber)): \(reason)"
		}
	}
}
