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

private actor RecordingRemoteFileClient: RemoteFileClient {
	private let downloadData: Data
	private var downloadFailure: RemoteFileError?
	private let existingRemotePaths: Set<String>
	private(set) var downloadCallCount = 0
	private var uploadedDestinations: [String] = []

	init(
		downloadData: Data,
		downloadFailure: RemoteFileError? = nil,
		existingRemotePaths: Set<String> = []
	) {
		self.downloadData = downloadData
		self.downloadFailure = downloadFailure
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
	func rename(from: String, to: String) async throws {}
	func delete(_ path: String, isDirectory: Bool) async throws {}

	func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		uploadedDestinations.append(remotePath)
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
		try downloadData.write(to: localURL)
		await progress(TransferProgress(
			bytesTransferred: Int64(downloadData.count),
			totalBytes: Int64(downloadData.count)
		))
		if let downloadFailure { throw downloadFailure }
		return RemoteFileTransferResult(bytesTransferred: Int64(downloadData.count))
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
