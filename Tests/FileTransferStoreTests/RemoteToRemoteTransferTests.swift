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

	func testRemoteCopyProgressSaturatesUntrustedReportedSize() async throws {
		let sourceHost = makeHost(name: "Source")
		let destinationHost = makeHost(name: "Destination")
		let source = RelayRemoteFileClient(
			files: ["/source/report.txt": Data("new".utf8)],
			reportedSize: Int64.max
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
		XCTAssertEqual(task.status, .completed)
		XCTAssertEqual(task.progress.totalBytes, Int64.max)
		XCTAssertEqual(task.progress.bytesTransferred, Int64.max)
	}

	func testRemoteDirectoryCopyUsesRecursivePayloadProgress() async throws {
		let sourceHost = makeHost(name: "Source")
		let destinationHost = makeHost(name: "Destination")
		let source = DirectoryRelayRemoteFileClient(
			payloads: [
				"first.txt": Data("four".utf8),
				"nested/second.txt": Data("sixsix".utf8),
			]
		)
		let destination = DirectoryRelayRemoteFileClient()
		let store = FileTransferStore { host in
			host.id == sourceHost.id ? source : destination
		}

		let taskID = try XCTUnwrap(
			store.enqueueRemoteCopy(
				remotePaths: ["/source/folder"],
				destinationDirectory: "/destination",
				sourceHost: sourceHost,
				destinationHost: destinationHost
			).first
		)
		try await store.waitIdle()

		let task = try XCTUnwrap(store.task(id: taskID))
		XCTAssertEqual(task.status, .completed)
		XCTAssertTrue(task.isDirectory)
		XCTAssertEqual(task.progress.totalBytes, 20)
		XCTAssertEqual(task.progress.bytesTransferred, 20)
		let receivedBytes = await destination.receivedPayloadBytes()
		XCTAssertEqual(receivedBytes, 10)
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

private actor DirectoryRelayRemoteFileClient: RemoteFileClient {
	private var payloads: [String: Data]
	private var stagedPayloadBytes: [String: Int64] = [:]
	private var receivedBytes: Int64 = 0

	init(payloads: [String: Data] = [:]) {
		self.payloads = payloads
	}

	func receivedPayloadBytes() -> Int64 {
		receivedBytes
	}

	func list(_ path: String) async throws -> [RemoteEntry] {
		[]
	}

	func stat(_ path: String) async throws -> RemoteEntry? {
		guard !payloads.isEmpty || stagedPayloadBytes[path] != nil else {
			return nil
		}
		return RemoteEntry(
			name: (path as NSString).lastPathComponent,
			isDirectory: true,
			size: 4_096,
			mtime: Date(timeIntervalSince1970: 1_700_000_000),
			mode: 0o700
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
		guard isDirectory else {
			throw RemoteFileError.invalidResponse(
				message: "Expected directory upload"
			)
		}
		let bytes = try Self.regularFileBytes(in: localURL)
		stagedPayloadBytes[remotePath] = bytes
		await progress(
			TransferProgress(
				bytesTransferred: bytes,
				totalBytes: bytes
			)
		)
		return RemoteFileTransferResult(bytesTransferred: bytes)
	}

	func download(
		remotePath: String,
		localURL: URL,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		guard isDirectory else {
			throw RemoteFileError.invalidResponse(
				message: "Expected directory download"
			)
		}
		try FileManager.default.createDirectory(
			at: localURL,
			withIntermediateDirectories: true
		)
		for (relativePath, data) in payloads {
			let destination = localURL.appendingPathComponent(relativePath)
			try FileManager.default.createDirectory(
				at: destination.deletingLastPathComponent(),
				withIntermediateDirectories: true
			)
			try data.write(to: destination)
		}
		let bytes = payloads.values.reduce(Int64(0)) {
			$0 + Int64($1.count)
		}
		await progress(
			TransferProgress(
				bytesTransferred: bytes,
				totalBytes: bytes
			)
		)
		return RemoteFileTransferResult(bytesTransferred: bytes)
	}

	func createDirectory(_ path: String) async throws {}

	func rename(from: String, to: String) async throws {
		guard let bytes = stagedPayloadBytes.removeValue(forKey: from) else {
			throw RemoteFileError.notFound(path: from)
		}
		receivedBytes = bytes
		stagedPayloadBytes[to] = bytes
	}

	func delete(_ path: String, isDirectory: Bool) async throws {
		stagedPayloadBytes[path] = nil
	}

	nonisolated private static func regularFileBytes(
		in root: URL
	) throws -> Int64 {
		guard let enumerator = FileManager.default.enumerator(
			at: root,
			includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
		) else {
			return 0
		}
		var total: Int64 = 0
		for case let child as URL in enumerator {
			let values = try child.resourceValues(
				forKeys: [.isRegularFileKey, .fileSizeKey]
			)
			if values.isRegularFile == true {
				total += Int64(values.fileSize ?? 0)
			}
		}
		return total
	}
}

private actor RelayRemoteFileClient: RemoteFileClient {
	private var files: [String: Data]
	private var uploadPaths: [String] = []
	private var renameTargets: [String] = []
	private var downloads = 0
	private let reportedSize: Int64?

	init(
		files: [String: Data] = [:],
		reportedSize: Int64? = nil
	) {
		self.files = files
		self.reportedSize = reportedSize
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
				size: reportedSize ?? Int64(data.count),
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
			size: reportedSize ?? Int64(data.count),
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
