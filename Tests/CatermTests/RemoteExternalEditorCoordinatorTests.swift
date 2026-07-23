import FileTransferStore
import Foundation
import SSHCommandBuilder
import Testing
@testable import Caterm

@Suite(.serialized)
@MainActor
struct RemoteExternalEditorCoordinatorTests {
	@Test
	func stagesPrivatelyOpensChosenEditorAndCleansUp() async throws {
		let root = temporaryRoot()
		let client = ExternalEditRemoteClient(
			data: Data("original".utf8),
			modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
		)
		let recorder = ExternalEditOpenRecorder()
		let host = makeHost()
		let store = FileTransferStore { _ in client }
		let coordinator = RemoteExternalEditorCoordinator(
			rootURL: root,
			openEditor: { fileURL, editorURL in
				await recorder.record(
					fileURL: fileURL,
					editorURL: editorURL
				)
				return nil
			}
		)
		let editorURL = URL(fileURLWithPath: "/Applications/TextEdit.app")

		await coordinator.start(
			side: .left,
			remotePath: "~/notes.txt",
			editorURL: editorURL,
			host: host,
			transferStore: store
		)

		let session = try #require(coordinator.session(for: .left))
		guard case .watching(uploadedAt: nil) = session.state else {
			Issue.record("Expected the staged file to be watched")
			return
		}
		let directoryAttributes = try FileManager.default.attributesOfItem(
			atPath: session.stagedURL.deletingLastPathComponent().path
		)
		let fileAttributes = try FileManager.default.attributesOfItem(
			atPath: session.stagedURL.path
		)
		#expect(
			(directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
				== 0o700
		)
		#expect(
			(fileAttributes[.posixPermissions] as? NSNumber)?.intValue
				== 0o600
		)
		let opened = await recorder.value()
		#expect(opened?.fileURL == session.stagedURL)
		#expect(opened?.editorURL == editorURL)

		await coordinator.close(side: .left)

		#expect(coordinator.session(for: .left) == nil)
		#expect(!FileManager.default.fileExists(atPath: session.stagedURL.path))
	}

	@Test
	func modifiedDraftRequiresReviewAndPublishesThroughRemoteSibling() async throws {
		let root = temporaryRoot()
		let client = ExternalEditRemoteClient(
			data: Data("original".utf8),
			modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
		)
		let host = makeHost()
		let store = FileTransferStore { _ in client }
		let coordinator = RemoteExternalEditorCoordinator(
			rootURL: root,
			openEditor: { _, _ in nil }
		)
		await coordinator.start(
			side: .right,
			remotePath: "/srv/config.txt",
			editorURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
			host: host,
			transferStore: store
		)
		let session = try #require(coordinator.session(for: .right))
		try Data("local edit".utf8).write(
			to: session.stagedURL,
			options: .atomic
		)

		await coordinator.refreshLocalModification(side: .right)
		#expect(coordinator.session(for: .right)?.state == .modified)
		await coordinator.reviewUpload(side: .right)
		#expect(
			coordinator.session(for: .right)?.state
				== .awaitingUploadConfirmation
		)
		await coordinator.upload(side: .right, replacingRemote: false)

		let updated = try #require(coordinator.session(for: .right))
		guard case .watching(let uploadedAt) = updated.state else {
			Issue.record("Expected the uploaded draft to return to watching")
			return
		}
		#expect(uploadedAt != nil)
		#expect(await client.remoteData() == Data("local edit".utf8))
		let rename = await client.lastRename()
		#expect(rename?.to == "/srv/config.txt")
		#expect(rename?.from.contains(".config.txt.caterm-partial-") == true)
		await coordinator.closeAll()
	}

	@Test
	func changedRemoteOffersDownloadNewerInsteadOfOverwriting() async throws {
		let root = temporaryRoot()
		let client = ExternalEditRemoteClient(
			data: Data("original".utf8),
			modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
		)
		let host = makeHost()
		let store = FileTransferStore { _ in client }
		let coordinator = RemoteExternalEditorCoordinator(
			rootURL: root,
			openEditor: { _, _ in nil }
		)
		await coordinator.start(
			side: .left,
			remotePath: "/srv/config.txt",
			editorURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
			host: host,
			transferStore: store
		)
		let session = try #require(coordinator.session(for: .left))
		try Data("local edit".utf8).write(
			to: session.stagedURL,
			options: .atomic
		)
		await coordinator.refreshLocalModification(side: .left)
		await client.replaceRemote(
			with: Data("remote edit".utf8),
			modifiedAt: Date(timeIntervalSince1970: 1_700_000_100)
		)

		await coordinator.reviewUpload(side: .left)

		#expect(
			coordinator.session(for: .left)?.state.conflictComparison
				== .changed
		)
		await coordinator.downloadNewer(side: .left)
		#expect(
			try Data(contentsOf: session.stagedURL)
				== Data("remote edit".utf8)
		)
		guard case .watching(uploadedAt: nil) =
			coordinator.session(for: .left)?.state else {
			Issue.record("Expected the newer remote file to resume watching")
			return
		}
		await coordinator.closeAll()
	}

	@Test
	func missingRemoteTimestampFallsBackToContentDigest() async throws {
		let coordinator = RemoteExternalEditorCoordinator(
			rootURL: temporaryRoot(),
			openEditor: { _, _ in nil }
		)
		let client = ExternalEditRemoteClient(
			data: Data("original".utf8),
			modifiedAt: nil
		)
		let host = makeHost()
		let store = FileTransferStore { _ in client }
		await coordinator.start(
			side: .left,
			remotePath: "/srv/config.txt",
			editorURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
			host: host,
			transferStore: store
		)
		let session = try #require(coordinator.session(for: .left))
		try Data("local edit".utf8).write(
			to: session.stagedURL,
			options: .atomic
		)
		await coordinator.refreshLocalModification(side: .left)

		await coordinator.reviewUpload(side: .left)

		#expect(
			coordinator.session(for: .left)?.state
				== .awaitingUploadConfirmation
		)
		await coordinator.closeAll()
	}

	@Test
	func digestDetectsSameSizeRemoteChangeWithoutTimestamp() async throws {
		let coordinator = RemoteExternalEditorCoordinator(
			rootURL: temporaryRoot(),
			openEditor: { _, _ in nil }
		)
		let client = ExternalEditRemoteClient(
			data: Data("original".utf8),
			modifiedAt: nil
		)
		let host = makeHost()
		let store = FileTransferStore { _ in client }
		await coordinator.start(
			side: .left,
			remotePath: "/srv/config.txt",
			editorURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
			host: host,
			transferStore: store
		)
		let session = try #require(coordinator.session(for: .left))
		try Data("local-ed".utf8).write(
			to: session.stagedURL,
			options: .atomic
		)
		await coordinator.refreshLocalModification(side: .left)
		await client.replaceRemote(
			with: Data("external".utf8),
			modifiedAt: nil
		)

		await coordinator.reviewUpload(side: .left)

		#expect(
			coordinator.session(for: .left)?.state.conflictComparison
				== .changed
		)
		await coordinator.closeAll()
	}

	@Test
	func prePublishCheckStopsRemoteChangeDuringUpload() async throws {
		let coordinator = RemoteExternalEditorCoordinator(
			rootURL: temporaryRoot(),
			openEditor: { _, _ in nil }
		)
		let client = ExternalEditRemoteClient(
			data: Data("original".utf8),
			modifiedAt: nil
		)
		let host = makeHost()
		let store = FileTransferStore { _ in client }
		await coordinator.start(
			side: .left,
			remotePath: "/srv/config.txt",
			editorURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
			host: host,
			transferStore: store
		)
		let session = try #require(coordinator.session(for: .left))
		try Data("local-ed".utf8).write(
			to: session.stagedURL,
			options: .atomic
		)
		await coordinator.refreshLocalModification(side: .left)
		await coordinator.reviewUpload(side: .left)
		await client.changeRemoteDuringNextUpload(
			to: Data("external".utf8)
		)

		await coordinator.upload(side: .left, replacingRemote: false)

		#expect(
			coordinator.session(for: .left)?.state.conflictComparison
				== .changed
		)
		#expect(await client.lastRename() == nil)
		#expect(!store.tasks.contains { $0.status == .conflict })
		await coordinator.closeAll()
	}

	@Test
	func failedStagingTransferIsConsumedByExternalEditor() async throws {
		let coordinator = RemoteExternalEditorCoordinator(
			rootURL: temporaryRoot(),
			openEditor: { _, _ in nil }
		)
		let client = ExternalEditRemoteClient(
			data: Data("original".utf8),
			modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
		)
		await client.failNextDownload()
		let host = makeHost()
		let store = FileTransferStore { _ in client }

		await coordinator.start(
			side: .left,
			remotePath: "/srv/config.txt",
			editorURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
			host: host,
			transferStore: store
		)

		guard case .failed = coordinator.session(for: .left)?.state else {
			Issue.record("Expected the staging failure to stay in the editor banner")
			return
		}
		#expect(!store.tasks.contains { $0.status == .failed })
		await coordinator.retry(side: .left)
		guard case .watching =
			coordinator.session(for: .left)?.state else {
			Issue.record("Expected staging retry to reopen the draft")
			return
		}
		await coordinator.closeAll()
	}

	@Test
	func failedUploadIsConsumedWithoutLeavingBrokenQueueRetry() async throws {
		let coordinator = RemoteExternalEditorCoordinator(
			rootURL: temporaryRoot(),
			openEditor: { _, _ in nil }
		)
		let client = ExternalEditRemoteClient(
			data: Data("original".utf8),
			modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
		)
		let host = makeHost()
		let store = FileTransferStore { _ in client }
		await coordinator.start(
			side: .left,
			remotePath: "/srv/config.txt",
			editorURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
			host: host,
			transferStore: store
		)
		let session = try #require(coordinator.session(for: .left))
		try Data("local edit".utf8).write(
			to: session.stagedURL,
			options: .atomic
		)
		await coordinator.refreshLocalModification(side: .left)
		await coordinator.reviewUpload(side: .left)
		await client.failNextUpload()

		await coordinator.upload(side: .left, replacingRemote: false)

		guard case .failed = coordinator.session(for: .left)?.state else {
			Issue.record("Expected the upload failure to stay in the editor banner")
			return
		}
		#expect(!store.tasks.contains { $0.status == .failed })
		await coordinator.retry(side: .left)
		guard case .watching =
			coordinator.session(for: .left)?.state else {
			Issue.record("Expected upload retry to restore the editing session")
			return
		}
		#expect(await client.remoteData() == Data("local edit".utf8))
		await coordinator.closeAll()
	}

	@Test
	func secondCoordinatorDoesNotDeleteAnActiveDraft() async throws {
		let root = temporaryRoot()
		let first = RemoteExternalEditorCoordinator(
			rootURL: root,
			openEditor: { _, _ in nil }
		)
		let second = RemoteExternalEditorCoordinator(
			rootURL: root,
			openEditor: { _, _ in nil }
		)
		let host = makeHost()
		let firstClient = ExternalEditRemoteClient(
			data: Data("first".utf8),
			modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
		)
		let secondClient = ExternalEditRemoteClient(
			data: Data("second".utf8),
			modifiedAt: Date(timeIntervalSince1970: 1_700_000_001)
		)
		await first.start(
			side: .left,
			remotePath: "/srv/first.txt",
			editorURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
			host: host,
			transferStore: FileTransferStore { _ in firstClient }
		)
		let firstSession = try #require(first.session(for: .left))

		await second.start(
			side: .right,
			remotePath: "/srv/second.txt",
			editorURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
			host: host,
			transferStore: FileTransferStore { _ in secondClient }
		)

		#expect(
			FileManager.default.fileExists(atPath: firstSession.stagedURL.path)
		)
		#expect(RemoteExternalEditorRegistry.shared.hasActiveSessions)
		await first.closeAll()
		await second.closeAll()
		#expect(!RemoteExternalEditorRegistry.shared.hasActiveSessions)
	}

	@Test
	func cleanupFailureKeepsDraftVisibleAndRetryable() async throws {
		let root = temporaryRoot()
		let coordinator = RemoteExternalEditorCoordinator(
			rootURL: root,
			openEditor: { _, _ in nil }
		)
		let client = ExternalEditRemoteClient(
			data: Data("draft".utf8),
			modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
		)
		let host = makeHost()
		await coordinator.start(
			side: .left,
			remotePath: "/srv/config.txt",
			editorURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
			host: host,
			transferStore: FileTransferStore { _ in client }
		)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o500],
			ofItemAtPath: root.path
		)
		defer {
			try? FileManager.default.setAttributes(
				[.posixPermissions: 0o700],
				ofItemAtPath: root.path
			)
			try? FileManager.default.removeItem(at: root)
		}

		let cleaned = await coordinator.close(side: .left)

		#expect(!cleaned)
		guard case .failed(message: _, retry: .cleanup) =
			coordinator.session(for: .left)?.state else {
			Issue.record("Expected cleanup failure to remain visible")
			return
		}
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o700],
			ofItemAtPath: root.path
		)
		await coordinator.retry(side: .left)
		#expect(coordinator.session(for: .left) == nil)
	}

	private func temporaryRoot() -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent(
				"caterm-external-editor-tests-\(UUID().uuidString)",
				isDirectory: true
			)
	}

	private func makeHost() -> SSHHost {
		SSHHost(
			id: UUID(),
			name: "Fixture",
			hostname: "localhost",
			port: 22,
			username: "fixture",
			credential: .agent
		)
	}
}

private extension RemoteExternalEditSession.State {
	var conflictComparison: RemoteFileRevision.Comparison? {
		guard case .conflict(let metadata) = self else { return nil }
		return metadata.comparison
	}
}

private actor ExternalEditOpenRecorder {
	struct Opened: Sendable {
		let fileURL: URL
		let editorURL: URL
	}

	private var opened: Opened?

	func record(fileURL: URL, editorURL: URL) {
		opened = Opened(fileURL: fileURL, editorURL: editorURL)
	}

	func value() -> Opened? {
		opened
	}
}

private actor ExternalEditRemoteClient: RemoteFileClient {
	private let primaryPath = "/srv/config.txt"
	private var data: Data
	private var modifiedAt: Date?
	private var staged: [String: Data] = [:]
	private var renameRecord: (from: String, to: String)?
	private var remoteChangeDuringUpload: Data?
	private var shouldFailNextDownload = false
	private var shouldFailNextUpload = false

	init(data: Data, modifiedAt: Date?) {
		self.data = data
		self.modifiedAt = modifiedAt
	}

	func list(_ path: String) async throws -> [RemoteEntry] {
		[]
	}

	func stat(_ path: String) async throws -> RemoteEntry? {
		if let stagedData = staged[path] {
			return entry(
				path: path,
				data: stagedData,
				modifiedAt: modifiedAt
			)
		}
		return entry(path: path, data: data, modifiedAt: modifiedAt)
	}

	func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		replaceExisting: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		if shouldFailNextUpload {
			shouldFailNextUpload = false
			throw RemoteFileError.transport(message: "fixture upload failure")
		}
		let uploaded = try Data(contentsOf: localURL)
		staged[remotePath] = uploaded
		if let remoteChangeDuringUpload {
			data = remoteChangeDuringUpload
			modifiedAt = nil
			self.remoteChangeDuringUpload = nil
		}
		await progress(
			TransferProgress(
				bytesTransferred: Int64(uploaded.count),
				totalBytes: Int64(uploaded.count)
			)
		)
		return RemoteFileTransferResult(
			bytesTransferred: Int64(uploaded.count)
		)
	}

	func download(
		remotePath: String,
		localURL: URL,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		if shouldFailNextDownload {
			shouldFailNextDownload = false
			throw RemoteFileError.transport(message: "fixture download failure")
		}
		try data.write(to: localURL, options: .atomic)
		await progress(
			TransferProgress(
				bytesTransferred: Int64(data.count),
				totalBytes: Int64(data.count)
			)
		)
		return RemoteFileTransferResult(
			bytesTransferred: Int64(data.count)
		)
	}

	func createDirectory(_ path: String) async throws {}

	func rename(from: String, to: String) async throws {
		guard let uploaded = staged.removeValue(forKey: from) else {
			throw RemoteFileError.notFound(path: from)
		}
		data = uploaded
		modifiedAt = modifiedAt.map { $0.addingTimeInterval(1) }
			?? Date(timeIntervalSince1970: 1_700_000_001)
		renameRecord = (from, to)
	}

	func delete(_ path: String, isDirectory: Bool) async throws {
		staged[path] = nil
	}

	func remoteData() -> Data {
		data
	}

	func lastRename() -> (from: String, to: String)? {
		renameRecord
	}

	func replaceRemote(with data: Data, modifiedAt: Date?) {
		self.data = data
		self.modifiedAt = modifiedAt
	}

	func changeRemoteDuringNextUpload(to data: Data) {
		remoteChangeDuringUpload = data
	}

	func failNextDownload() {
		shouldFailNextDownload = true
	}

	func failNextUpload() {
		shouldFailNextUpload = true
	}

	private func entry(
		path: String,
		data: Data,
		modifiedAt: Date?
	) -> RemoteEntry {
		RemoteEntry(
			name: (path as NSString).lastPathComponent,
			type: .file,
			size: Int64(data.count),
			mtime: modifiedAt,
			mode: 0o600,
			canonicalPath: path
		)
	}
}
