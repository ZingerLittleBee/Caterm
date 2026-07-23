import FileTransferStore
import Foundation
import SSHCommandBuilder
import XCTest

@MainActor
final class RemoteToRemoteTransferTests: XCTestCase {
	func testRemoteCopyPublishesTemporaryUploadThroughMac() async throws {
		let sourceHost = makeHost(name: "Source")
		let destinationHost = makeHost(name: "Destination")
		let payload = Data("remote payload".utf8)
		let source = RelayRemoteFileClient(
			files: ["/source/report.txt": payload]
		)
		let destination = RelayRemoteFileClient()
		let store = makeStore(
			sourceHost: sourceHost,
			source: source,
			destinationHost: destinationHost,
			destination: destination
		)

		let taskID = try XCTUnwrap(
			store.enqueueRemoteCopy(
				remotePaths: ["/source/report.txt"],
				destinationDirectory: "/destination",
				sourceHost: sourceHost,
				destinationHost: destinationHost
			).first
		)
		try await store.waitIdle()

		let task = try XCTUnwrap(store.task(id: taskID))
		XCTAssertEqual(task.kind, .remoteCopy)
		XCTAssertEqual(task.route, .viaThisMac)
		XCTAssertEqual(task.sourceHostId, sourceHost.id)
		XCTAssertEqual(task.hostId, destinationHost.id)
		XCTAssertEqual(task.status, .completed)
		XCTAssertEqual(task.destination, "/destination/report.txt")
		let publishedData = await destination.data(
			at: "/destination/report.txt"
		)
		XCTAssertEqual(publishedData, payload)
		let uploads = await destination.uploadedPaths()
		XCTAssertEqual(uploads.count, 1)
		XCTAssertTrue(
			try XCTUnwrap(uploads.first)
				.contains(".report.txt.caterm-partial-")
		)
		let renamedDestinations = await destination.renamedDestinations()
		XCTAssertEqual(renamedDestinations, ["/destination/report.txt"])
		XCTAssertGreaterThanOrEqual(
			task.progress.bytesTransferred,
			Int64(payload.count * 2)
		)
	}

	func testRemoteCopyWaitsForConflictBeforeDownloadingSource() async throws {
		let sourceHost = makeHost(name: "Source")
		let destinationHost = makeHost(name: "Destination")
		let payload = Data("new".utf8)
		let source = RelayRemoteFileClient(
			files: ["/source/report.txt": payload]
		)
		let destination = RelayRemoteFileClient(
			files: ["/destination/report.txt": Data("old".utf8)]
		)
		let store = makeStore(
			sourceHost: sourceHost,
			source: source,
			destinationHost: destinationHost,
			destination: destination
		)

		let taskID = try XCTUnwrap(
			store.enqueueRemoteCopy(
				remotePaths: ["/source/report.txt"],
				destinationDirectory: "/destination",
				sourceHost: sourceHost,
				destinationHost: destinationHost
			).first
		)
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: taskID)?.status, .conflict)
		let downloadsBeforeResolution = await source.downloadCount()
		XCTAssertEqual(downloadsBeforeResolution, 0)
		store.resolveConflict(taskID, policy: .keepBoth)
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: taskID)?.status, .completed)
		XCTAssertEqual(
			store.task(id: taskID)?.destination,
			"/destination/report 2.txt"
		)
		let copiedData = await destination.data(
			at: "/destination/report 2.txt"
		)
		let originalData = await destination.data(
			at: "/destination/report.txt"
		)
		XCTAssertEqual(copiedData, payload)
		XCTAssertEqual(originalData, Data("old".utf8))
	}

	func testRemovingSourceHostCancelsAndDiscardsRemoteCopy() async throws {
		let sourceHost = makeHost(name: "Source")
		let destinationHost = makeHost(name: "Destination")
		let source = RelayRemoteFileClient(
			files: ["/source/report.txt": Data("new".utf8)]
		)
		let destination = RelayRemoteFileClient(
			files: ["/destination/report.txt": Data("old".utf8)]
		)
		let store = makeStore(
			sourceHost: sourceHost,
			source: source,
			destinationHost: destinationHost,
			destination: destination
		)
		let taskID = try XCTUnwrap(
			store.enqueueRemoteCopy(
				remotePaths: ["/source/report.txt"],
				destinationDirectory: "/destination",
				sourceHost: sourceHost,
				destinationHost: destinationHost
			).first
		)
		try await store.waitIdle()
		XCTAssertEqual(store.task(id: taskID)?.status, .conflict)

		await store.commitHostRemoval(sourceHost.id)

		XCTAssertNil(store.task(id: taskID))
		XCTAssertTrue(
			store.enqueueRemoteCopy(
				remotePaths: ["/source/report.txt"],
				destinationDirectory: "/destination",
				sourceHost: sourceHost,
				destinationHost: destinationHost
			).isEmpty
		)
	}

	private func makeStore(
		sourceHost: SSHHost,
		source: RelayRemoteFileClient,
		destinationHost: SSHHost,
		destination: RelayRemoteFileClient
	) -> FileTransferStore {
		FileTransferStore { host in
			switch host.id {
			case sourceHost.id:
				source
			case destinationHost.id:
				destination
			default:
				UnavailableRelayRemoteFileClient()
			}
		}
	}

	private func makeHost(name: String) -> SSHHost {
		SSHHost(
			id: UUID(),
			name: name,
			hostname: "localhost",
			port: 22,
			username: "fixture",
			credential: .agent
		)
	}
}

private actor RelayRemoteFileClient: RemoteFileClient {
	private var files: [String: Data]
	private var uploadPaths: [String] = []
	private var renameTargets: [String] = []
	private var downloads = 0

	init(files: [String: Data] = [:]) {
		self.files = files
	}

	func data(at path: String) -> Data? {
		files[path]
	}

	func uploadedPaths() -> [String] {
		uploadPaths
	}

	func renamedDestinations() -> [String] {
		renameTargets
	}

	func downloadCount() -> Int {
		downloads
	}

	func list(_ path: String) async throws -> [RemoteEntry] {
		files.compactMap { filePath, data in
			guard (filePath as NSString).deletingLastPathComponent == path else {
				return nil
			}
			return RemoteEntry(
				name: (filePath as NSString).lastPathComponent,
				isDirectory: false,
				size: Int64(data.count),
				mtime: Date(timeIntervalSince1970: 1_700_000_000),
				mode: 0o600
			)
		}
	}

	func stat(_ path: String) async throws -> RemoteEntry? {
		guard let data = files[path] else { return nil }
		return RemoteEntry(
			name: (path as NSString).lastPathComponent,
			isDirectory: false,
			size: Int64(data.count),
			mtime: Date(timeIntervalSince1970: 1_700_000_000),
			mode: 0o600
		)
	}

	func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		replaceExisting: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		let data = try Data(contentsOf: localURL)
		uploadPaths.append(remotePath)
		files[remotePath] = data
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

	func download(
		remotePath: String,
		localURL: URL,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		guard let data = files[remotePath] else {
			throw RemoteFileError.notFound(path: remotePath)
		}
		downloads += 1
		try data.write(to: localURL)
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
		guard let data = files.removeValue(forKey: from) else {
			throw RemoteFileError.notFound(path: from)
		}
		files[to] = data
		renameTargets.append(to)
	}

	func delete(_ path: String, isDirectory: Bool) async throws {
		files[path] = nil
	}
}

private actor UnavailableRelayRemoteFileClient: RemoteFileClient {
	func list(_ path: String) async throws -> [RemoteEntry] {
		throw RemoteFileError.sessionUnavailable
	}

	func stat(_ path: String) async throws -> RemoteEntry? {
		throw RemoteFileError.sessionUnavailable
	}

	func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		replaceExisting: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		throw RemoteFileError.sessionUnavailable
	}

	func download(
		remotePath: String,
		localURL: URL,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		throw RemoteFileError.sessionUnavailable
	}

	func createDirectory(_ path: String) async throws {
		throw RemoteFileError.sessionUnavailable
	}

	func rename(from: String, to: String) async throws {
		throw RemoteFileError.sessionUnavailable
	}

	func delete(_ path: String, isDirectory: Bool) async throws {
		throw RemoteFileError.sessionUnavailable
	}
}
