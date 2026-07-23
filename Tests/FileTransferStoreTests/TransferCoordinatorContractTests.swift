import Foundation
import XCTest
@testable import FileTransferStore
import SSHCommandBuilder

@MainActor
final class TransferCoordinatorContractTests: XCTestCase {
	private var temporaryDirectory: URL!

	override func setUp() async throws {
		try await super.setUp()
		temporaryDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-transfer-contract-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: temporaryDirectory,
			withIntermediateDirectories: true
		)
	}

	override func tearDown() async throws {
		try? FileManager.default.removeItem(at: temporaryDirectory)
		try await super.tearDown()
	}

	func testDownloadConflictWaitsForExplicitKeepBothPolicy() async throws {
		let destination = temporaryDirectory.appendingPathComponent("report.txt")
		try Data("existing".utf8).write(to: destination)
		let client = RecordingRemoteFileClient(downloadData: Data("fresh".utf8))
		let store = makeStore(client: client)

		let id = try XCTUnwrap(store.enqueueDownload(
			remotePaths: ["/remote/report.txt"],
			localDir: temporaryDirectory,
			host: makeHost()
		).first)
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: id)?.status, .conflict)
		let callsBeforeResolution = await client.downloadCalls()
		XCTAssertEqual(callsBeforeResolution, 0)

		store.resolveConflict(id, policy: .keepBoth)
		try await store.waitIdle()

		let completed = try XCTUnwrap(store.task(id: id))
		XCTAssertEqual(completed.status, .completed)
		XCTAssertNotEqual(completed.destination, destination.path)
		XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
		XCTAssertEqual(
			try Data(contentsOf: URL(fileURLWithPath: completed.destination)),
			Data("fresh".utf8)
		)
	}

	func testFailedDownloadNeverPublishesPartialDestination() async throws {
		let client = RecordingRemoteFileClient(
			downloadData: Data("partial".utf8),
			downloadFailure: .transport(message: "connection reset")
		)
		let store = makeStore(client: client)
		let destination = temporaryDirectory.appendingPathComponent("archive.bin")

		let id = try XCTUnwrap(store.enqueueDownload(
			remotePaths: ["/remote/archive.bin"],
			localDir: temporaryDirectory,
			host: makeHost()
		).first)
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: id)?.status, .failed)
		XCTAssertEqual(
			store.task(id: id)?.failure,
			.transport(message: "connection reset")
		)
		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
		XCTAssertTrue(try partialFiles().isEmpty)
	}

	func testCleanupFailurePreservesOriginalTypedFailure() async throws {
		let client = RecordingRemoteFileClient(
			downloadData: Data("partial".utf8),
			downloadFailure: .transport(message: "connection reset")
		)
		let store = FileTransferStore(
			clientForHost: { _ in client },
			localFiles: CleanupFailingLocalFiles()
		)

		let id = try XCTUnwrap(store.enqueueDownload(
			remotePaths: ["/remote/archive.bin"],
			localDir: temporaryDirectory,
			host: makeHost()
		).first)
		try await store.waitIdle()

		guard case .cleanupFailed(let original, let cleanupMessage) =
			store.task(id: id)?.failure else {
			return XCTFail("Expected cleanup failure")
		}
		XCTAssertEqual(original, .transport(message: "connection reset"))
		XCTAssertEqual(cleanupMessage, "fixture cleanup failure")
		XCTAssertEqual(try partialFiles().count, 1)
	}

	func testCancellationCleanupFailureKeepsStableCancelledState() async throws {
		let source = temporaryDirectory.appendingPathComponent("cancel.bin")
		try Data("bytes".utf8).write(to: source)
		let client = RecordingRemoteFileClient(
			downloadData: Data(),
			uploadFailure: .cleanupFailed(
				original: .cancelled,
				cleanupMessage: "cleanup host unavailable"
			)
		)
		let store = makeStore(client: client)

		let id = try XCTUnwrap(store.enqueueUpload(
			localPaths: [source],
			remoteDir: "/remote",
			host: makeHost()
		).first)
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: id)?.status, .cancelled)
		XCTAssertNil(store.task(id: id)?.failure)
	}

	func testDownloadReplacePublishesCompleteBytesOverExistingDestination() async throws {
		let destination = temporaryDirectory.appendingPathComponent("replace.txt")
		try Data("old".utf8).write(to: destination)
		let client = RecordingRemoteFileClient(downloadData: Data("new".utf8))
		let store = makeStore(client: client)

		let id = try XCTUnwrap(store.enqueueDownload(
			remotePaths: ["/remote/replace.txt"],
			localDir: temporaryDirectory,
			host: makeHost(),
			conflictPolicy: .replace
		).first)
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: id)?.status, .completed)
		XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
		XCTAssertTrue(try partialFiles().isEmpty)
	}

	func testDownloadCarriesDirectoryIntentToTransport() async throws {
		let client = RecordingRemoteFileClient(
			downloadData: Data("archive".utf8)
		)
		let store = makeStore(client: client)
		let remotePath = "/remote/archive"

		let id = try XCTUnwrap(store.enqueueDownload(
			remotePaths: [remotePath],
			localDir: temporaryDirectory,
			host: makeHost(),
			directoryPaths: [remotePath]
		).first)
		try await store.waitIdle()

		let directoryFlags = await client.downloadDirectoryFlags()
		XCTAssertEqual(store.task(id: id)?.status, .completed)
		XCTAssertEqual(store.task(id: id)?.isDirectory, true)
		XCTAssertEqual(directoryFlags, [true])
	}

	func testUploadConflictRequiresPolicyBeforeTransportRuns() async throws {
		let local = temporaryDirectory.appendingPathComponent("upload.txt")
		try Data("upload".utf8).write(to: local)
		let client = RecordingRemoteFileClient(
			downloadData: Data(),
			existingRemotePaths: ["/remote/upload.txt"]
		)
		let store = makeStore(client: client)
		let id = try XCTUnwrap(store.enqueueUpload(
			localPaths: [local],
			remoteDir: "/remote",
			host: makeHost()
		).first)

		try await store.waitIdle()
		XCTAssertEqual(store.task(id: id)?.status, .conflict)
		let destinationsBeforeResolution = await client.uploadDestinations()
		XCTAssertTrue(destinationsBeforeResolution.isEmpty)

		store.resolveConflict(id, policy: .keepBoth)
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: id)?.status, .completed)
		XCTAssertEqual(store.task(id: id)?.destination, "/remote/upload 2.txt")
		let destinationsAfterResolution = await client.uploadDestinations()
		XCTAssertEqual(destinationsAfterResolution, ["/remote/upload 2.txt"])
	}

	func testUploadMetadataFailureMapsToLocalIO() async throws {
		let local = temporaryDirectory.appendingPathComponent("upload.txt")
		try Data("upload".utf8).write(to: local)
		let client = RecordingRemoteFileClient(downloadData: Data())
		let store = FileTransferStore(
			clientForHost: { _ in client },
			localFiles: MetadataFailingLocalFiles()
		)

		let id = try XCTUnwrap(store.enqueueUpload(
			localPaths: [local],
			remoteDir: "/remote",
			host: makeHost()
		).first)
		try await store.waitIdle()

		XCTAssertEqual(
			store.task(id: id)?.failure,
			.localIO(message: "fixture metadata failure")
		)
		let destinations = await client.uploadDestinations()
		XCTAssertTrue(destinations.isEmpty)
	}

	func testCancellingRunningDownloadRemovesPartialAndAdvancesQueue() async throws {
		let client = SuspendingRemoteFileClient()
		let store = makeStore(client: client)
		let destination = temporaryDirectory.appendingPathComponent("large.bin")
		let ids = store.enqueueDownload(
			remotePaths: ["/remote/large.bin", "/remote/next.bin"],
			localDir: temporaryDirectory,
			host: makeHost()
		)
		let id = try XCTUnwrap(ids.first)
		let nextID = try XCTUnwrap(ids.last)

		await client.waitUntilStarted()
		store.cancel(id)
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: id)?.status, .cancelled)
		XCTAssertEqual(store.task(id: nextID)?.status, .completed)
		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
		XCTAssertTrue(try partialFiles().isEmpty)
	}

	func testRetryPreservesIdentityAndClearsTypedFailure() async throws {
		let client = RecordingRemoteFileClient(
			downloadData: Data("complete".utf8),
			downloadFailure: .sessionUnavailable
		)
		let store = makeStore(client: client)
		let id = try XCTUnwrap(store.enqueueDownload(
			remotePaths: ["/remote/retry.txt"],
			localDir: temporaryDirectory,
			host: makeHost()
		).first)

		try await store.waitIdle()
		XCTAssertEqual(store.task(id: id)?.failure, .sessionUnavailable)

		await client.setDownloadFailure(nil)
		store.retry(id)
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: id)?.id, id)
		XCTAssertEqual(store.task(id: id)?.status, .completed)
		XCTAssertNil(store.task(id: id)?.failure)
		let callsAfterRetry = await client.downloadCalls()
		XCTAssertEqual(callsAfterRetry, 2)
	}

	func testRetryRequiresExplicitChoiceWhenUploadMayAlreadyBeCommitted() async throws {
		let local = temporaryDirectory.appendingPathComponent("ambiguous.txt")
		try Data("complete".utf8).write(to: local)
		let client = CommitThenFailUploadClient()
		let store = makeStore(client: client)
		let id = try XCTUnwrap(store.enqueueUpload(
			localPaths: [local],
			remoteDir: "/remote",
			host: makeHost(),
			conflictPolicy: .keepBoth
		).first)

		try await store.waitIdle()
		XCTAssertEqual(store.task(id: id)?.status, .failed)

		store.retry(id)
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: id)?.status, .conflict)
		XCTAssertEqual(store.task(id: id)?.destination, "/remote/ambiguous.txt")
		let calls = await client.uploadCalls()
		XCTAssertEqual(calls, 1)
	}

	func testCancelledTransferCanStartFreshAttempt() async throws {
		let client = SuspendingRemoteFileClient()
		let store = makeStore(client: client)
		let id = try XCTUnwrap(store.enqueueDownload(
			remotePaths: ["/remote/cancelled.txt"],
			localDir: temporaryDirectory,
			host: makeHost()
		).first)
		await client.waitUntilStarted()
		store.cancel(id)
		try await store.waitIdle()
		XCTAssertEqual(store.task(id: id)?.status, .cancelled)

		store.retry(id)
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: id)?.status, .completed)
		XCTAssertEqual(store.task(id: id)?.attemptCount, 1)
	}

	func testTerminalTaskWaiterCancelsWithoutPollingOrCancellingTransfer()
		async throws {
		let client = SuspendingRemoteFileClient()
		let store = makeStore(client: client)
		let id = try XCTUnwrap(store.enqueueDownload(
			remotePaths: ["/remote/waiter.txt"],
			localDir: temporaryDirectory,
			host: makeHost()
		).first)
		await client.waitUntilStarted()
		let waiter = Task {
			try await store.waitForTerminalTask(id)
		}

		waiter.cancel()

		do {
			_ = try await waiter.value
			XCTFail("Expected the waiter to observe cancellation")
		} catch is CancellationError {
			XCTAssertEqual(store.task(id: id)?.status, .running)
		}
		store.cancel(id)
		try await store.waitIdle()
	}

	func testCancellationAfterAtomicPublishKeepsTransferCompleted() async throws {
		let callback = AsyncCallbackBox()
		let client = RecordingRemoteFileClient(downloadData: Data("complete".utf8))
		let store = FileTransferStore(
			clientForHost: { _ in client },
			localFiles: PublishCancellingLocalFiles(callback: callback)
		)
		let destination = temporaryDirectory.appendingPathComponent("committed.txt")
		let id = try XCTUnwrap(store.enqueueDownload(
			remotePaths: ["/remote/committed.txt"],
			localDir: temporaryDirectory,
			host: makeHost()
		).first)
		await callback.install {
			await MainActor.run { store.cancel(id) }
		}

		try await store.waitIdle()

		XCTAssertEqual(store.task(id: id)?.status, .completed)
		XCTAssertEqual(try Data(contentsOf: destination), Data("complete".utf8))
		XCTAssertTrue(try partialFiles().isEmpty)
	}

	func testAtomicUploadPublishesThroughRemoteSiblingRename() async throws {
		let source = temporaryDirectory.appendingPathComponent("draft.txt")
		try Data("draft".utf8).write(to: source)
		let destination = "/remote/draft.txt"
		let client = RecordingRemoteFileClient(
			downloadData: Data(),
			existingRemotePaths: [destination]
		)
		let store = makeStore(client: client)

		let id = try XCTUnwrap(store.enqueueAtomicUpload(
			localFile: source,
			remotePath: destination,
			host: makeHost()
		))
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: id)?.status, .completed)
		let renames = await client.renameOperations()
		XCTAssertEqual(renames.count, 1)
		let rename = try XCTUnwrap(renames.first)
		XCTAssertEqual(rename.to, destination)
		XCTAssertTrue(
			rename.from.contains(".draft.txt.caterm-partial-")
		)
		let uploadDestinations = await client.uploadDestinations()
		XCTAssertEqual(
			uploadDestinations,
			[rename.from]
		)
	}

	func testBackgroundInterruptionCancelsRunningWorkWithoutForegroundReplay() async throws {
		let client = SuspendingRemoteFileClient()
		let store = makeStore(client: client)
		let id = try XCTUnwrap(store.enqueueDownload(
			remotePaths: ["/remote/background.bin"],
			localDir: temporaryDirectory,
			host: makeHost()
		).first)
		await client.waitUntilStarted()

		XCTAssertEqual(store.interruptForBackground(), 1)
		try await store.waitIdle()
		store.reconcileAfterForeground()

		XCTAssertEqual(store.task(id: id)?.status, .cancelled)
		XCTAssertEqual(
			store.lifecycleInterruption,
			TransferLifecycleInterruption(reason: .background, transferCount: 1)
		)
		XCTAssertTrue(try partialFiles().isEmpty)
		let calls = await client.downloadCalls()
		XCTAssertEqual(calls, 1)
	}

	func testBackgroundInterruptionNeverReplaysCompletedTransfer() async throws {
		let client = RecordingRemoteFileClient(downloadData: Data("complete".utf8))
		let store = makeStore(client: client)
		let id = try XCTUnwrap(store.enqueueDownload(
			remotePaths: ["/remote/completed.bin"],
			localDir: temporaryDirectory,
			host: makeHost()
		).first)
		try await store.waitIdle()

		XCTAssertEqual(store.interruptForBackground(), 0)
		let foregroundProbeHostID = UUID()
		XCTAssertNil(store.captureEnqueueContext(for: foregroundProbeHostID))
		store.reconcileAfterForeground()
		XCTAssertNotNil(store.captureEnqueueContext(for: foregroundProbeHostID))

		XCTAssertEqual(store.task(id: id)?.status, .completed)
		let calls = await client.downloadCalls()
		XCTAssertEqual(calls, 1)
	}

	func testBackgroundInvalidatesFilePreparationThatHasNotEnqueuedYet() throws {
		let store = makeStore(
			client: RecordingRemoteFileClient(downloadData: Data())
		)
		let host = makeHost()
		let context = try XCTUnwrap(store.captureEnqueueContext(for: host.id))
		let source = temporaryDirectory.appendingPathComponent("staged.txt")
		try Data("staged".utf8).write(to: source)

		XCTAssertEqual(store.interruptForBackground(), 0)
		let ids = store.enqueueUpload(
			localPaths: [source],
			remoteDir: "/remote",
			host: host,
			expectedContext: context
		)

		XCTAssertTrue(ids.isEmpty)
		XCTAssertTrue(store.tasks.isEmpty)
	}

	func testHostRemovalBlocksConcurrentEnqueueUntilAbort() async throws {
		let store = makeStore(
			client: RecordingRemoteFileClient(
				downloadData: Data(),
				uploadFailure: .sessionUnavailable
			)
		)
		let host = makeHost()
		let staleContext = try XCTUnwrap(store.captureEnqueueContext(for: host.id))
		let source = temporaryDirectory.appendingPathComponent("host-delete.txt")
		try Data("payload".utf8).write(to: source)
		let retainedID = try XCTUnwrap(store.enqueueUpload(
			localPaths: [source],
			remoteDir: "/remote",
			host: host,
			expectedContext: staleContext
		).first)
		try await store.waitIdle()

		let preparedRemoval = await store.prepareForHostRemoval(host.id)
		let removal = try XCTUnwrap(preparedRemoval)
		XCTAssertEqual(store.task(id: retainedID)?.status, .failed)
		XCTAssertNil(store.captureEnqueueContext(for: host.id))
		XCTAssertTrue(store.enqueueUpload(
			localPaths: [source],
			remoteDir: "/remote",
			host: host,
			expectedContext: staleContext
		).isEmpty)

		store.abortHostRemoval(removal)
		XCTAssertEqual(store.task(id: retainedID)?.status, .failed)
		let freshContext = try XCTUnwrap(store.captureEnqueueContext(for: host.id))
		XCTAssertEqual(store.enqueueUpload(
			localPaths: [source],
			remoteDir: "/remote",
			host: host,
			expectedContext: freshContext
		).count, 1)
	}

	func testCommittedHostRemovalRejectsStaleAndUnscopedEnqueues() async throws {
		let store = makeStore(
			client: RecordingRemoteFileClient(downloadData: Data())
		)
		let host = makeHost()
		let context = try XCTUnwrap(store.captureEnqueueContext(for: host.id))
		let source = temporaryDirectory.appendingPathComponent("removed-host.txt")
		try Data("payload".utf8).write(to: source)

		await store.commitHostRemoval(host.id)

		XCTAssertNil(store.captureEnqueueContext(for: host.id))
		XCTAssertTrue(store.enqueueUpload(
			localPaths: [source], remoteDir: "/remote", host: host
		).isEmpty)
		XCTAssertTrue(store.enqueueUpload(
			localPaths: [source],
			remoteDir: "/remote",
			host: host,
			expectedContext: context
		).isEmpty)
	}

	func testRestoredHostInvalidatesStaleRemovalCommit() async throws {
		let cleanup = DiscardedTransferRecorder()
		let client = RecordingRemoteFileClient(
			downloadData: Data(),
			uploadFailure: .sessionUnavailable
		)
		let store = FileTransferStore(
			clientForHost: { _ in client },
			didDiscard: { await cleanup.record($0) }
		)
		let host = makeHost()
		let source = temporaryDirectory.appendingPathComponent("restored-host.txt")
		try Data("payload".utf8).write(to: source)
		let taskID = try XCTUnwrap(store.enqueueUpload(
			localPaths: [source], remoteDir: "/remote", host: host
		).first)
		try await store.waitIdle()
		let preparedRemoval = await store.prepareForHostRemoval(host.id)
		let removal = try XCTUnwrap(preparedRemoval)

		store.restoreHost(host.id)
		await store.commitHostRemoval(removal)

		XCTAssertEqual(store.task(id: taskID)?.status, .failed)
		XCTAssertNotNil(store.captureEnqueueContext(for: host.id))
		let discardedIDs = await cleanup.taskIDs()
		XCTAssertTrue(discardedIDs.isEmpty)
	}

	func testAccountResetInvalidatesPendingPreparationContext() async throws {
		let store = makeStore(
			client: RecordingRemoteFileClient(downloadData: Data())
		)
		let host = makeHost()
		let context = try XCTUnwrap(store.captureEnqueueContext(for: host.id))
		let source = temporaryDirectory.appendingPathComponent("old-account.txt")
		try Data("payload".utf8).write(to: source)

		await store.resetForAccountChange()

		XCTAssertTrue(store.enqueueUpload(
			localPaths: [source],
			remoteDir: "/remote",
			host: host,
			expectedContext: context
		).isEmpty)
		XCTAssertNotNil(store.captureEnqueueContext(for: host.id))
	}

	func testHostRemovalDiscardsTasksAndInvokesPayloadCleanup() async throws {
		let cleanup = DiscardedTransferRecorder()
		let client = RecordingRemoteFileClient(
			downloadData: Data(),
			uploadFailure: .sessionUnavailable
		)
		let store = FileTransferStore(
			clientForHost: { _ in client },
			didDiscard: { await cleanup.record($0) }
		)
		let host = makeHost()
		let source = temporaryDirectory.appendingPathComponent("host-removal.bin")
		try Data("payload".utf8).write(to: source)
		let id = try XCTUnwrap(store.enqueueUpload(
			localPaths: [source],
			remoteDir: "/remote",
			host: host
		).first)
		try await store.waitIdle()
		XCTAssertEqual(store.task(id: id)?.status, .failed)

		await store.discardTasks(forHost: host.id)

		XCTAssertNil(store.task(id: id))
		let discarded = await cleanup.taskIDs()
		XCTAssertEqual(discarded, [id])
	}

	func testAccountResetDiscardsTasksAcrossHostsWithoutReplay() async throws {
		let cleanup = DiscardedTransferRecorder()
		let client = RecordingRemoteFileClient(
			downloadData: Data(),
			uploadFailure: .sessionUnavailable
		)
		let store = FileTransferStore(
			clientForHost: { _ in client },
			didDiscard: { await cleanup.record($0) }
		)
		let source = temporaryDirectory.appendingPathComponent("account-reset.bin")
		try Data("payload".utf8).write(to: source)
		let firstHost = makeHost()
		let secondHost = makeHost()
		let firstID = try XCTUnwrap(store.enqueueUpload(
			localPaths: [source], remoteDir: "/a", host: firstHost
		).first)
		let secondID = try XCTUnwrap(store.enqueueUpload(
			localPaths: [source], remoteDir: "/b", host: secondHost
		).first)
		try await store.waitIdle()

		await store.resetForAccountChange()
		store.reconcileAfterForeground()

		XCTAssertTrue(store.tasks.isEmpty)
		let discarded = Set(await cleanup.taskIDs())
		XCTAssertEqual(discarded, Set([firstID, secondID]))
	}

	func testProgressNeverMovesBackward() {
		let initial = TransferProgress(bytesTransferred: 12, totalBytes: 20)
		XCTAssertEqual(
			initial.advancing(to: TransferProgress(bytesTransferred: 7, totalBytes: 20)),
			initial
		)
		XCTAssertEqual(
			initial.advancing(to: TransferProgress(bytesTransferred: 18, totalBytes: 20)),
			TransferProgress(bytesTransferred: 18, totalBytes: 20)
		)
	}

	private func makeStore(client: any RemoteFileClient) -> FileTransferStore {
		FileTransferStore(clientForHost: { _ in client })
	}

	private func makeHost() -> SSHHost {
		SSHHost(
			id: UUID(), name: "fixture", hostname: "localhost", port: 22,
			username: "tester", credential: .agent
		)
	}

	private func partialFiles() throws -> [URL] {
		try FileManager.default.contentsOfDirectory(
			at: temporaryDirectory,
			includingPropertiesForKeys: nil
		).filter { $0.lastPathComponent.contains(".caterm-partial-") }
	}
}

private actor CleanupFailingLocalFiles: LocalTransferFileCoordinating {
	private let base = LocalTransferFileCoordinator()

	func isDirectory(at url: URL) async throws -> Bool {
		try await base.isDirectory(at: url)
	}

	func prepareDestination(
		_ requested: URL,
		policy: TransferConflictPolicy?
	) async throws -> DestinationPreparation<URL> {
		try await base.prepareDestination(requested, policy: policy)
	}

	func temporaryDestination(for destination: URL) async throws -> URL {
		try await base.temporaryDestination(for: destination)
	}

	func publish(
		temporary: URL,
		to destination: URL,
		replacing: Bool
	) async throws {
		try await base.publish(
			temporary: temporary,
			to: destination,
			replacing: replacing
		)
	}

	func remove(_ url: URL) async throws {
		throw CleanupFailure.fixture
	}

	private enum CleanupFailure: LocalizedError {
		case fixture

		var errorDescription: String? { "fixture cleanup failure" }
	}
}

private actor MetadataFailingLocalFiles: LocalTransferFileCoordinating {
	private let base = LocalTransferFileCoordinator()

	func isDirectory(at url: URL) async throws -> Bool {
		throw MetadataFailure.fixture
	}

	func prepareDestination(
		_ requested: URL,
		policy: TransferConflictPolicy?
	) async throws -> DestinationPreparation<URL> {
		try await base.prepareDestination(requested, policy: policy)
	}

	func temporaryDestination(for destination: URL) async throws -> URL {
		try await base.temporaryDestination(for: destination)
	}

	func publish(
		temporary: URL,
		to destination: URL,
		replacing: Bool
	) async throws {
		try await base.publish(
			temporary: temporary,
			to: destination,
			replacing: replacing
		)
	}

	func remove(_ url: URL) async throws {
		try await base.remove(url)
	}

	private enum MetadataFailure: LocalizedError {
		case fixture

		var errorDescription: String? { "fixture metadata failure" }
	}
}

private actor AsyncCallbackBox {
	private var callback: (@Sendable () async -> Void)?

	func install(_ callback: @escaping @Sendable () async -> Void) {
		self.callback = callback
	}

	func run() async {
		while callback == nil { await Task.yield() }
		await callback?()
	}
}

private actor PublishCancellingLocalFiles: LocalTransferFileCoordinating {
	private let base = LocalTransferFileCoordinator()
	private let callback: AsyncCallbackBox

	init(callback: AsyncCallbackBox) {
		self.callback = callback
	}

	func isDirectory(at url: URL) async throws -> Bool {
		try await base.isDirectory(at: url)
	}

	func prepareDestination(
		_ requested: URL,
		policy: TransferConflictPolicy?
	) async throws -> DestinationPreparation<URL> {
		try await base.prepareDestination(requested, policy: policy)
	}

	func temporaryDestination(for destination: URL) async throws -> URL {
		try await base.temporaryDestination(for: destination)
	}

	func publish(
		temporary: URL,
		to destination: URL,
		replacing: Bool
	) async throws {
		try await base.publish(
			temporary: temporary,
			to: destination,
			replacing: replacing
		)
		await callback.run()
	}

	func remove(_ url: URL) async throws {
		try await base.remove(url)
	}
}

private actor RecordingRemoteFileClient: RemoteFileClient {
	private let downloadData: Data
	private var downloadFailure: RemoteFileError?
	private let uploadFailure: RemoteFileError?
	private let existingRemotePaths: Set<String>
	private(set) var downloadCallCount = 0
	private var uploadedDestinations: [String] = []
	private var directoryFlags: [Bool] = []
	private var renames: [(from: String, to: String)] = []

	init(
		downloadData: Data,
		downloadFailure: RemoteFileError? = nil,
		uploadFailure: RemoteFileError? = nil,
		existingRemotePaths: Set<String> = []
	) {
		self.downloadData = downloadData
		self.downloadFailure = downloadFailure
		self.uploadFailure = uploadFailure
		self.existingRemotePaths = existingRemotePaths
	}

	func setDownloadFailure(_ failure: RemoteFileError?) {
		downloadFailure = failure
	}

	func downloadCalls() -> Int {
		downloadCallCount
	}

	func uploadDestinations() -> [String] {
		uploadedDestinations
	}

	func downloadDirectoryFlags() -> [Bool] {
		directoryFlags
	}

	func renameOperations() -> [(from: String, to: String)] {
		renames
	}

	func list(_ path: String) async throws -> [RemoteEntry] { [] }
	func stat(_ path: String) async throws -> RemoteEntry? {
		guard existingRemotePaths.contains(path) else { return nil }
		return RemoteEntry(
			name: (path as NSString).lastPathComponent,
			isDirectory: false,
			size: 0,
			mtime: nil,
			mode: 0
		)
	}
	func createDirectory(_ path: String) async throws {}
	func rename(from: String, to: String) async throws {
		renames.append((from, to))
	}
	func delete(_ path: String, isDirectory: Bool) async throws {}

	func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		replaceExisting: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		uploadedDestinations.append(remotePath)
		if let uploadFailure { throw uploadFailure }
		let size = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
		return RemoteFileTransferResult(bytesTransferred: Int64(size))
	}

	func download(
		remotePath: String,
		localURL: URL,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		downloadCallCount += 1
		directoryFlags.append(isDirectory)
		try downloadData.write(to: localURL)
		await progress(TransferProgress(
			bytesTransferred: Int64(downloadData.count),
			totalBytes: Int64(downloadData.count)
		))
		if let downloadFailure { throw downloadFailure }
		return RemoteFileTransferResult(bytesTransferred: Int64(downloadData.count))
	}
}

private actor CommitThenFailUploadClient: RemoteFileClient {
	private var committedPaths: Set<String> = []
	private var uploadCallCount = 0

	func uploadCalls() -> Int { uploadCallCount }
	func list(_ path: String) async throws -> [RemoteEntry] { [] }
	func stat(_ path: String) async throws -> RemoteEntry? {
		guard committedPaths.contains(path) else { return nil }
		return RemoteEntry(
			name: (path as NSString).lastPathComponent,
			isDirectory: false,
			size: 8,
			mtime: nil,
			mode: 0
		)
	}
	func createDirectory(_ path: String) async throws {}
	func rename(from: String, to: String) async throws {}
	func delete(_ path: String, isDirectory: Bool) async throws {}

	func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		replaceExisting: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		uploadCallCount += 1
		committedPaths.insert(remotePath)
		throw RemoteFileError.transport(message: "commit acknowledgement lost")
	}

	func download(
		remotePath: String,
		localURL: URL,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		throw RemoteFileError.unsupported(operation: "download")
	}
}

private actor SuspendingRemoteFileClient: RemoteFileClient {
	private var started = false
	private var downloadCallCount = 0

	func waitUntilStarted() async {
		while !started {
			await Task.yield()
		}
	}

	func downloadCalls() -> Int { downloadCallCount }

	func list(_ path: String) async throws -> [RemoteEntry] { [] }
	func stat(_ path: String) async throws -> RemoteEntry? { nil }
	func createDirectory(_ path: String) async throws {}
	func rename(from: String, to: String) async throws {}
	func delete(_ path: String, isDirectory: Bool) async throws {}

	func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		replaceExisting: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		RemoteFileTransferResult(bytesTransferred: 0)
	}

	func download(
		remotePath: String,
		localURL: URL,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		downloadCallCount += 1
		if downloadCallCount > 1 {
			let data = Data("complete".utf8)
			try data.write(to: localURL)
			return RemoteFileTransferResult(bytesTransferred: Int64(data.count))
		}
		started = true
		try Data("partial".utf8).write(to: localURL)
		await progress(TransferProgress(bytesTransferred: 7, totalBytes: nil))
		while true {
			try await Task.sleep(for: .seconds(1))
		}
	}
}

private actor DiscardedTransferRecorder {
	private var ids: [TaskId] = []

	func record(_ task: TransferTask) {
		ids.append(task.id)
	}

	func taskIDs() -> [TaskId] { ids }
}
