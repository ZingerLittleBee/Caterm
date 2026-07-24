import FileTransferStore
import Foundation
@testable import CatermMobile
import SSHCommandBuilder
import XCTest

final class MobileFileTransferTests: XCTestCase {
	func testStagingPreservesFileNameAndCopiesBytesIntoOwnedWorkspace() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-workspace-\(UUID().uuidString)")
		let sourceRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-source-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: sourceRoot,
			withIntermediateDirectories: true
		)
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: sourceRoot)
		}
		let source = sourceRoot.appendingPathComponent("report.txt")
		let bytes = Data("fixture bytes".utf8)
		try bytes.write(to: source)
		let workspace = MobileTransferWorkspace(rootURL: root)

		let staged = try await workspace.importUploadSources([source])

		let copy = try XCTUnwrap(staged.first)
		XCTAssertEqual(copy.lastPathComponent, "report.txt")
		XCTAssertEqual(try Data(contentsOf: copy), bytes)
		XCTAssertTrue(copy.path.hasPrefix(root.path))
	}

	func testUploadImportBalancesSecurityScopedAccessAroundCopy() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-scope-\(UUID().uuidString)")
		let source = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-scope-source-\(UUID().uuidString).txt")
		try Data("scoped".utf8).write(to: source)
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: source)
		}
		let recorder = SecurityScopeRecorder()
		let workspace = MobileTransferWorkspace(
			rootURL: root,
			securityScope: MobileSecurityScope(
				start: { recorder.start($0) },
				stop: { recorder.stop($0) }
			)
		)

		_ = try await workspace.importUploadSources([source])

		XCTAssertEqual(recorder.startedURLs(), [source])
		XCTAssertEqual(recorder.stoppedURLs(), [source])
	}

	func testDownloadsDirectoryIsStableAndCreated() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-downloads-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let workspace = MobileTransferWorkspace(rootURL: root)

		let first = try await workspace.downloadsDirectory()
		let second = try await workspace.downloadsDirectory()

		XCTAssertEqual(first, second)
		var isDirectory: ObjCBool = false
		XCTAssertTrue(FileManager.default.fileExists(
			atPath: first.path,
			isDirectory: &isDirectory
		))
		XCTAssertTrue(isDirectory.boolValue)
	}

	func testCompletedDownloadPreparesFilesAndDragExportInsideWorkspace() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-export-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let workspace = MobileTransferWorkspace(rootURL: root)
		let downloads = try await workspace.downloadsDirectory()
		let file = downloads.appendingPathComponent("report.pdf")
		try Data("export".utf8).write(to: file)
		let task = TransferTask(
			id: UUID(),
			kind: .download,
			hostId: UUID(),
			source: "/remote/report.pdf",
			destination: file.path,
			isDirectory: false,
			state: .completed(TransferProgress(bytesTransferred: 6, totalBytes: 6))
		)

		let store = await FileTransferStore(clientForHost: { _ in CountingMobileSession() })
		let export = try await MobileTransferActions(
			store: store,
			workspace: workspace
		).prepareExport(for: task)

		XCTAssertEqual(export.fileURL, file)
		XCTAssertEqual(export.suggestedName, "report.pdf")
		XCTAssertEqual(try Data(contentsOf: export.fileURL), Data("export".utf8))
	}

	@MainActor
	func testPublicUploadActionStagesAndEnqueuesFilesPickerOrDropURLs() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-actions-\(UUID().uuidString)")
		let source = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-action-source-\(UUID().uuidString).txt")
		try Data("public action".utf8).write(to: source)
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: source)
		}
		let workspace = MobileTransferWorkspace(rootURL: root)
		let store = FileTransferStore(clientForHost: { _ in CountingMobileSession() })
		let host = SSHHost(
			name: "fixture", hostname: "localhost", port: 22,
			username: "tester", credential: .agent
		)
		let actions = MobileTransferActions(store: store, workspace: workspace)

		let ids = try await actions.upload(
			sourceURLs: [source],
			context: MobileFileActionContext(host: host, parentPath: "/uploads")
		)
		try await store.waitIdle()

		let task = try XCTUnwrap(ids.first.flatMap { store.task(id: $0) })
		XCTAssertEqual(task.status, .completed)
		XCTAssertEqual(task.destination, "/uploads/\(source.lastPathComponent)")
	}

	@MainActor
	func testPublicDownloadActionUsesSharedKeepBothConflictPolicy() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-download-action-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let workspace = MobileTransferWorkspace(rootURL: root)
		let downloads = try await workspace.downloadsDirectory()
		let existing = downloads.appendingPathComponent("report.txt")
		try Data("existing".utf8).write(to: existing)
		let client = DownloadDataMobileSession(data: Data("downloaded".utf8))
		let store = FileTransferStore(clientForHost: { _ in client })
		let host = SSHHost(
			name: "fixture", hostname: "localhost", port: 22,
			username: "tester", credential: .agent
		)
		let actions = MobileTransferActions(store: store, workspace: workspace)

		let ids = try await actions.download(
			remotePaths: ["/remote/report.txt"],
			context: MobileFileActionContext(host: host, parentPath: "/remote")
		)
		try await store.waitIdle()
		let id = try XCTUnwrap(ids.first)
		XCTAssertEqual(store.task(id: id)?.status, .conflict)

		actions.resolveConflict(id, policy: .keepBoth)
		try await store.waitIdle()

		let completed = try XCTUnwrap(store.task(id: id))
		XCTAssertEqual(completed.status, .completed)
		XCTAssertEqual(URL(fileURLWithPath: completed.destination).lastPathComponent, "report 2.txt")
		XCTAssertEqual(try Data(contentsOf: existing), Data("existing".utf8))
		XCTAssertEqual(
			try Data(contentsOf: URL(fileURLWithPath: completed.destination)),
			Data("downloaded".utf8)
		)
	}

	@MainActor
	func testPublicUploadActionReportsPermissionLossWithoutEnqueueing() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-action-permission-\(UUID().uuidString)")
		let source = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-action-protected-\(UUID().uuidString).bin")
		try Data("protected".utf8).write(to: source)
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: source)
		}
		let workspace = MobileTransferWorkspace(
			rootURL: root,
			fileManager: PermissionFailingFileManager()
		)
		let store = FileTransferStore(clientForHost: { _ in CountingMobileSession() })
		let host = SSHHost(
			name: "fixture", hostname: "localhost", port: 22,
			username: "tester", credential: .agent
		)
		let actions = MobileTransferActions(store: store, workspace: workspace)

		do {
			_ = try await actions.upload(
				sourceURLs: [source],
				context: MobileFileActionContext(host: host, parentPath: "/uploads")
			)
			XCTFail("Expected permission failure")
		} catch RemoteFileError.localIO(let message) {
			XCTAssertFalse(message.isEmpty)
		}

		XCTAssertTrue(store.tasks.isEmpty)
		try assertTransferWorkingDirectoriesAreEmpty(root: root)
	}

	@MainActor
	func testRejectedUploadReportsQueueInputCleanupFailure() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-action-cleanup-\(UUID().uuidString)")
		let source = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-action-cleanup-\(UUID().uuidString).txt")
		try Data("cleanup failure".utf8).write(to: source)
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: source)
		}
		let store = FileTransferStore(clientForHost: { _ in CountingMobileSession() })
		let workspace = MobileTransferWorkspace(
			rootURL: root,
			fileManager: RemovalFailingFileManager(),
			securityScope: MobileSecurityScope(
				start: { _ in
					let interrupted = DispatchSemaphore(value: 0)
					Task { @MainActor in
						store.interruptForBackground()
						interrupted.signal()
					}
					interrupted.wait()
					return false
				},
				stop: { _ in }
			)
		)
		let host = SSHHost(
			name: "fixture", hostname: "localhost", port: 22,
			username: "tester", credential: .agent
		)
		let actions = MobileTransferActions(store: store, workspace: workspace)

		do {
			_ = try await actions.upload(
				sourceURLs: [source],
				context: MobileFileActionContext(host: host, parentPath: "/uploads")
			)
			XCTFail("Expected rejected upload cleanup failure")
		} catch RemoteFileError.cleanupFailed(let original, let message) {
			XCTAssertEqual(original, .sessionUnavailable)
			XCTAssertFalse(message.isEmpty)
		}

		XCTAssertTrue(store.tasks.isEmpty)
	}

	@MainActor
	func testPublicActionsCancelAtBackgroundAndNeverReplayOnForeground() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-action-background-\(UUID().uuidString)")
		let source = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-action-background-\(UUID().uuidString).txt")
		try Data("background upload".utf8).write(to: source)
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: source)
		}
		let workspace = MobileTransferWorkspace(rootURL: root)
		let client = CancellableDownloadMobileSession()
		let store = FileTransferStore(clientForHost: { _ in client })
		let lifecycle = MobileTransferLifecycleCoordinator(store: store)
		let sceneID = UUID()
		let host = SSHHost(
			name: "fixture", hostname: "localhost", port: 22,
			username: "tester", credential: .agent
		)
		let context = MobileFileActionContext(host: host, parentPath: "/remote")
		let actions = MobileTransferActions(store: store, workspace: workspace)
		lifecycle.updateScene(sceneID, state: .active)

		let ids = try await actions.download(
			remotePaths: ["/remote/large.bin"],
			context: context
		)
		let id = try XCTUnwrap(ids.first)
		try await waitForTransferStatus(.running, id: id, store: store)
		try await waitForDownloadCall(client)

		lifecycle.updateScene(sceneID, state: .background)
		try await store.waitIdle()
		XCTAssertEqual(store.task(id: id)?.status, .cancelled)
		let callsAfterBackground = await client.downloadCalls()
		XCTAssertEqual(callsAfterBackground, 1)

		do {
			_ = try await actions.upload(sourceURLs: [source], context: context)
			XCTFail("Expected background admission rejection")
		} catch RemoteFileError.sessionUnavailable {
			// Expected.
		}
		XCTAssertEqual(store.tasks.count, 1)

		lifecycle.updateScene(sceneID, state: .active)
		try await store.waitIdle()
		XCTAssertEqual(store.task(id: id)?.status, .cancelled)
		let callsAfterForeground = await client.downloadCalls()
		XCTAssertEqual(callsAfterForeground, 1)
	}

	@MainActor
	func testPublicActionsRetainQueueInputForCancelledRetryThenCleanItOnSuccess() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-action-retry-\(UUID().uuidString)")
		let source = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-action-retry-\(UUID().uuidString).txt")
		try Data("retry payload".utf8).write(to: source)
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: source)
		}
		let workspace = MobileTransferWorkspace(rootURL: root)
		let client = CancellableThenSuccessfulUploadMobileSession()
		let cleanup: @Sendable (TransferTask) async -> Void = { task in
			guard task.kind == .upload else { return }
			try? await workspace.removeUploadPayload(
				at: URL(fileURLWithPath: task.source)
			)
		}
		let store = FileTransferStore(
			clientForHost: { _ in client },
			didComplete: cleanup,
			didDiscard: cleanup
		)
		let host = SSHHost(
			name: "fixture", hostname: "localhost", port: 22,
			username: "tester", credential: .agent
		)
		let actions = MobileTransferActions(store: store, workspace: workspace)

		let ids = try await actions.upload(
			sourceURLs: [source],
			context: MobileFileActionContext(host: host, parentPath: "/uploads")
		)
		let id = try XCTUnwrap(ids.first)
		try await waitForTransferStatus(.running, id: id, store: store)
		try await waitForUploadCall(client)
		let queueInput = URL(fileURLWithPath: try XCTUnwrap(store.task(id: id)?.source))

		actions.cancel(id)
		try await store.waitIdle()
		XCTAssertEqual(store.task(id: id)?.status, .cancelled)
		XCTAssertTrue(FileManager.default.fileExists(atPath: queueInput.path))
		try assertDirectoryIsEmpty(root.appendingPathComponent("Staging", isDirectory: true))

		actions.retry(id)
		try await store.waitIdle()
		XCTAssertEqual(store.task(id: id)?.status, .completed)
		let uploadCalls = await client.uploadCalls()
		XCTAssertEqual(uploadCalls, 2)
		XCTAssertFalse(FileManager.default.fileExists(
			atPath: queueInput.deletingLastPathComponent().path
		))
	}

	@MainActor
	func testPublicDiscardCleansQueueInputAfterFailedUpload() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-action-failure-\(UUID().uuidString)")
		let source = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-action-failure-\(UUID().uuidString).txt")
		try Data("failed payload".utf8).write(to: source)
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: source)
		}
		let workspace = MobileTransferWorkspace(rootURL: root)
		let cleanup: @Sendable (TransferTask) async -> Void = { task in
			guard task.kind == .upload else { return }
			try? await workspace.removeUploadPayload(
				at: URL(fileURLWithPath: task.source)
			)
		}
		let store = FileTransferStore(
			clientForHost: { _ in FailingUploadMobileSession() },
			didDiscard: cleanup
		)
		let host = SSHHost(
			name: "fixture", hostname: "localhost", port: 22,
			username: "tester", credential: .agent
		)
		let actions = MobileTransferActions(store: store, workspace: workspace)

		let ids = try await actions.upload(
			sourceURLs: [source],
			context: MobileFileActionContext(host: host, parentPath: "/uploads")
		)
		let id = try XCTUnwrap(ids.first)
		try await store.waitIdle()
		let queueInput = URL(fileURLWithPath: try XCTUnwrap(store.task(id: id)?.source))
		XCTAssertEqual(store.task(id: id)?.status, .failed)
		XCTAssertTrue(FileManager.default.fileExists(atPath: queueInput.path))
		try assertDirectoryIsEmpty(root.appendingPathComponent("Staging", isDirectory: true))

		await actions.discard(id)

		XCTAssertNil(store.task(id: id))
		XCTAssertFalse(FileManager.default.fileExists(
			atPath: queueInput.deletingLastPathComponent().path
		))
	}

	@MainActor
	func testHostRemovalAndAccountResetCleanOwnedUploadInputs() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-action-reset-\(UUID().uuidString)")
		let sourceRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-action-reset-sources-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: sourceRoot)
		}
		let firstSource = sourceRoot.appendingPathComponent("first.txt")
		let secondSource = sourceRoot.appendingPathComponent("second.txt")
		try Data("first".utf8).write(to: firstSource)
		try Data("second".utf8).write(to: secondSource)
		let workspace = MobileTransferWorkspace(rootURL: root)
		let cleanup: @Sendable (TransferTask) async -> Void = { task in
			guard task.kind == .upload else { return }
			try? await workspace.removeUploadPayload(
				at: URL(fileURLWithPath: task.source)
			)
		}
		let store = FileTransferStore(
			clientForHost: { _ in FailingUploadMobileSession() },
			didDiscard: cleanup
		)
		let firstHost = SSHHost(
			name: "first", hostname: "localhost", port: 22,
			username: "tester", credential: .agent
		)
		let secondHost = SSHHost(
			name: "second", hostname: "localhost", port: 22,
			username: "tester", credential: .agent
		)
		let actions = MobileTransferActions(store: store, workspace: workspace)

		_ = try await actions.upload(
			sourceURLs: [firstSource],
			context: MobileFileActionContext(host: firstHost, parentPath: "/uploads")
		)
		try await store.waitIdle()
		let preparedRemoval = await store.prepareForHostRemoval(firstHost.id)
		let removal = try XCTUnwrap(preparedRemoval)
		await store.commitHostRemoval(removal)
		try assertDirectoryIsEmpty(root.appendingPathComponent("Payloads", isDirectory: true))

		_ = try await actions.upload(
			sourceURLs: [secondSource],
			context: MobileFileActionContext(host: secondHost, parentPath: "/uploads")
		)
		try await store.waitIdle()
		await store.resetForAccountChange()
		try assertDirectoryIsEmpty(root.appendingPathComponent("Payloads", isDirectory: true))
		XCTAssertTrue(store.tasks.isEmpty)
	}

	@MainActor
	func testMultiwindowLifecycleSuspendsOnlyAfterLastActiveSceneBackgrounds() {
		let store = FileTransferStore(clientForHost: { _ in CountingMobileSession() })
		let lifecycle = MobileTransferLifecycleCoordinator(store: store)
		let firstScene = UUID()
		let secondScene = UUID()
		let hostID = UUID()

		lifecycle.updateScene(firstScene, state: .active)
		lifecycle.updateScene(secondScene, state: .active)
		XCTAssertNotNil(store.captureEnqueueContext(for: hostID))

		lifecycle.updateScene(firstScene, state: .background)
		XCTAssertNotNil(store.captureEnqueueContext(for: hostID))

		lifecycle.updateScene(secondScene, state: .background)
		XCTAssertNil(store.captureEnqueueContext(for: hostID))

		lifecycle.updateScene(firstScene, state: .active)
		XCTAssertNotNil(store.captureEnqueueContext(for: hostID))
	}

	func testExportRejectsCompletedPathOutsideOwnedDownloads() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-export-scope-\(UUID().uuidString)")
		let outside = FileManager.default.temporaryDirectory
			.appendingPathComponent("outside-\(UUID().uuidString).txt")
		try Data("outside".utf8).write(to: outside)
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: outside)
		}
		let workspace = MobileTransferWorkspace(rootURL: root)
		let task = TransferTask(
			id: UUID(), kind: .download, hostId: UUID(),
			source: "/remote/outside.txt", destination: outside.path,
			isDirectory: false,
			state: .completed(TransferProgress(bytesTransferred: 7, totalBytes: 7))
		)

		do {
			_ = try await workspace.prepareExport(for: task)
			XCTFail("Expected export scope rejection")
		} catch RemoteFileError.localIO {
			// Expected.
		}
	}

	func testCompletedUploadCleanupRemovesOnlyOwnedPayloadDirectory() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-cleanup-\(UUID().uuidString)")
		let sourceRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-source-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: sourceRoot)
		}
		let source = sourceRoot.appendingPathComponent("upload.bin")
		try Data("bytes".utf8).write(to: source)
		let workspace = MobileTransferWorkspace(rootURL: root)
		let stagedURLs = try await workspace.importUploadSources([source])
		let staged = try XCTUnwrap(stagedURLs.first)

		try await workspace.removeUploadPayload(at: staged)
		try await workspace.removeUploadPayload(at: source)

		XCTAssertFalse(FileManager.default.fileExists(
			atPath: staged.deletingLastPathComponent().path
		))
		XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
	}

	func testBatchStagingFailureRollsBackEarlierCopies() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-rollback-\(UUID().uuidString)")
		let sourceRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-source-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: sourceRoot)
		}
		let file = sourceRoot.appendingPathComponent("first.txt")
		let directory = sourceRoot.appendingPathComponent("folder", isDirectory: true)
		try Data("first".utf8).write(to: file)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let workspace = MobileTransferWorkspace(rootURL: root)

		do {
			_ = try await workspace.importUploadSources([file, directory])
			XCTFail("Expected directory upload rejection")
		} catch RemoteFileError.unsupported {
			// Expected.
		}

		try assertTransferWorkingDirectoriesAreEmpty(root: root)
	}

	func testCopyFailureRollsBackCurrentPartialStagingDirectory() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-partial-\(UUID().uuidString)")
		let source = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-source-\(UUID().uuidString).bin")
		try Data("complete source".utf8).write(to: source)
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: source)
		}
		let workspace = MobileTransferWorkspace(
			rootURL: root,
			fileManager: PartiallyFailingFileManager()
		)

		do {
			_ = try await workspace.importUploadSources([source])
			XCTFail("Expected staging copy failure")
		} catch RemoteFileError.localIO {
			// Expected.
		}

		try assertTransferWorkingDirectoriesAreEmpty(root: root)
	}

	func testPermissionLossReportsLocalIOAndLeavesNoTransferData() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-permission-\(UUID().uuidString)")
		let source = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-mobile-protected-\(UUID().uuidString).bin")
		try Data("protected".utf8).write(to: source)
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: source)
		}
		let workspace = MobileTransferWorkspace(
			rootURL: root,
			fileManager: PermissionFailingFileManager()
		)

		do {
			_ = try await workspace.importUploadSources([source])
			XCTFail("Expected permission failure")
		} catch RemoteFileError.localIO(let message) {
			XCTAssertFalse(message.isEmpty)
		}

		try assertTransferWorkingDirectoriesAreEmpty(root: root)
	}

	private func assertTransferWorkingDirectoriesAreEmpty(root: URL) throws {
		for name in ["Staging", "Payloads"] {
			try assertDirectoryIsEmpty(root.appendingPathComponent(name, isDirectory: true))
		}
	}

	private func assertDirectoryIsEmpty(_ directory: URL) throws {
		let remaining = try FileManager.default.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: nil
		)
		XCTAssertTrue(
			remaining.isEmpty,
			"Expected empty \(directory.lastPathComponent) directory"
		)
	}

	@MainActor
	private func waitForTransferStatus(
		_ status: TransferTask.Status,
		id: TaskId,
		store: FileTransferStore
	) async throws {
		let deadline = ContinuousClock.now + .seconds(2)
		while store.task(id: id)?.status != status {
			guard ContinuousClock.now < deadline else {
				XCTFail("Timed out waiting for transfer status \(status)")
				return
			}
			await Task.yield()
		}
	}

	private func waitForDownloadCall(
		_ client: CancellableDownloadMobileSession
	) async throws {
		let deadline = ContinuousClock.now + .seconds(2)
		while await client.downloadCalls() == 0 {
			guard ContinuousClock.now < deadline else {
				XCTFail("Timed out waiting for download transport")
				return
			}
			await Task.yield()
		}
	}

	private func waitForUploadCall(
		_ client: CancellableThenSuccessfulUploadMobileSession
	) async throws {
		let deadline = ContinuousClock.now + .seconds(2)
		while await client.uploadCalls() == 0 {
			guard ContinuousClock.now < deadline else {
				XCTFail("Timed out waiting for upload transport")
				return
			}
			await Task.yield()
		}
	}

	@MainActor
	func testDeferredClientSharesConcurrentFirstConnection() async throws {
		let counter = MobileSessionFactoryCounter()
		let session = CountingMobileSession()
		let factory = MobileRemoteFileClientFactory { _ in
			await counter.recordCall()
			try await Task.sleep(for: .milliseconds(25))
			return session
		}
		let host = SSHHost(
			name: "fixture",
			hostname: "localhost",
			port: 22,
			username: "tester",
			credential: .agent
		)
		let client = MobileDeferredRemoteFileClient(host: host, factory: factory)

		async let first = client.list("~")
		async let second = client.stat("~")
		_ = try await (first, second)

		let factoryCalls = await counter.calls()
		XCTAssertEqual(factoryCalls, 1)
	}
}

private final class PartiallyFailingFileManager: FileManager {
	override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
		try Data("partial".utf8).write(to: destinationURL)
		throw CocoaError(.fileWriteOutOfSpace)
	}
}

private final class PermissionFailingFileManager: FileManager {
	override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
		throw CocoaError(.fileReadNoPermission)
	}
}

private final class RemovalFailingFileManager: FileManager {
	override func removeItem(at URL: URL) throws {
		if URL.path.contains("/Payloads/") {
			throw CocoaError(.fileWriteNoPermission)
		}
		try super.removeItem(at: URL)
	}
}

private final class SecurityScopeRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var started: [URL] = []
	private var stopped: [URL] = []

	func start(_ url: URL) -> Bool {
		lock.withLock { started.append(url) }
		return true
	}

	func stop(_ url: URL) {
		lock.withLock { stopped.append(url) }
	}

	func startedURLs() -> [URL] { lock.withLock { started } }
	func stoppedURLs() -> [URL] { lock.withLock { stopped } }
}

private actor MobileSessionFactoryCounter {
	private var callCount = 0

	func recordCall() { callCount += 1 }
	func calls() -> Int { callCount }
}

private actor CountingMobileSession: MobileRemoteFileSession {
	func list(_ path: String) async throws -> [RemoteEntry] { [] }
	func stat(_ path: String) async throws -> RemoteEntry? { nil }
	func createDirectory(_ path: String) async throws {}
	func rename(from: String, to: String) async throws {}
	func delete(_ path: String, isDirectory: Bool) async throws {}
	func disconnect() async {}

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
		RemoteFileTransferResult(bytesTransferred: 0)
	}
}

private actor DownloadDataMobileSession: MobileRemoteFileSession {
	private let data: Data

	init(data: Data) {
		self.data = data
	}

	func list(_ path: String) async throws -> [RemoteEntry] { [] }
	func stat(_ path: String) async throws -> RemoteEntry? { nil }
	func createDirectory(_ path: String) async throws {}
	func rename(from: String, to: String) async throws {}
	func delete(_ path: String, isDirectory: Bool) async throws {}
	func disconnect() async {}

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
		try data.write(to: localURL)
		await progress(TransferProgress(
			bytesTransferred: Int64(data.count),
			totalBytes: Int64(data.count)
		))
		return RemoteFileTransferResult(bytesTransferred: Int64(data.count))
	}
}

private actor CancellableDownloadMobileSession: MobileRemoteFileSession {
	private var downloadCallCount = 0

	func downloadCalls() -> Int { downloadCallCount }
	func list(_ path: String) async throws -> [RemoteEntry] { [] }
	func stat(_ path: String) async throws -> RemoteEntry? { nil }
	func createDirectory(_ path: String) async throws {}
	func rename(from: String, to: String) async throws {}
	func delete(_ path: String, isDirectory: Bool) async throws {}
	func disconnect() async {}

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
		await progress(TransferProgress(bytesTransferred: 1, totalBytes: 10))
		try await Task.sleep(for: .seconds(30))
		return RemoteFileTransferResult(bytesTransferred: 10)
	}
}

private actor CancellableThenSuccessfulUploadMobileSession: MobileRemoteFileSession {
	private var uploadCallCount = 0

	func uploadCalls() -> Int { uploadCallCount }
	func list(_ path: String) async throws -> [RemoteEntry] { [] }
	func stat(_ path: String) async throws -> RemoteEntry? { nil }
	func createDirectory(_ path: String) async throws {}
	func rename(from: String, to: String) async throws {}
	func delete(_ path: String, isDirectory: Bool) async throws {}
	func disconnect() async {}

	func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		replaceExisting: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		uploadCallCount += 1
		if uploadCallCount == 1 {
			await progress(TransferProgress(bytesTransferred: 1, totalBytes: 10))
			try await Task.sleep(for: .seconds(30))
		}
		let bytes = try Data(contentsOf: localURL).count
		return RemoteFileTransferResult(bytesTransferred: Int64(bytes))
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

private actor FailingUploadMobileSession: MobileRemoteFileSession {
	func list(_ path: String) async throws -> [RemoteEntry] { [] }
	func stat(_ path: String) async throws -> RemoteEntry? { nil }
	func createDirectory(_ path: String) async throws {}
	func rename(from: String, to: String) async throws {}
	func delete(_ path: String, isDirectory: Bool) async throws {}
	func disconnect() async {}

	func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		replaceExisting: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		throw RemoteFileError.transport(message: "fixture upload failure")
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
