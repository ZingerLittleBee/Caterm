@testable import FileTransferStore
import Foundation
import SSHCommandBuilder
import XCTest

@MainActor
final class LocalFileLocationStoreTests: XCTestCase {
	func testInvalidPersistenceReportsRecoverableLoadError() async throws {
		let root = makeTemporaryDirectory()
		let persistenceURL = root.appendingPathComponent("locations.json")
		try Data("{not-json".utf8).write(to: persistenceURL)

		let store = LocalFileLocationStore(
			fileURL: persistenceURL,
			bookmarkCodec: RecordingBookmarkCodec()
		)

		let locations = await store.locations
		XCTAssertTrue(locations.isEmpty)
		guard case .invalidData = await store.loadError else {
			XCTFail("Expected invalid persisted data to remain visible")
			return
		}
		_ = try await store.add(url: root, displayName: "Recovered")
		let recoveredLoadError = await store.loadError
		XCTAssertNil(recoveredLoadError)
	}

	func testStaleBookmarkIsRebuiltBeforeAccess() async throws {
		let root = makeTemporaryDirectory()
		let persistenceURL = root.appendingPathComponent("locations.json")
		let selectedURL = root.appendingPathComponent("Selected")
		try FileManager.default.createDirectory(
			at: selectedURL,
			withIntermediateDirectories: false
		)
		let codec = RecordingBookmarkCodec(staleResolutions: 1)
		let firstStore = LocalFileLocationStore(
			fileURL: persistenceURL,
			bookmarkCodec: codec
		)
		let location = try await firstStore.add(
			url: selectedURL,
			displayName: "Workspace"
		)
		let reloadedStore = LocalFileLocationStore(
			fileURL: persistenceURL,
			bookmarkCodec: codec
		)

		let grant = try await reloadedStore.access(location.id)
		let resolvedPath = try await grant.withAccess { url in
			url.path
		}

		XCTAssertEqual(resolvedPath, selectedURL.path)
		XCTAssertEqual(codec.bookmarkCreationCount, 2)
		XCTAssertEqual(codec.startCount, 1)
		XCTAssertEqual(codec.stopCount, 1)
		let persisted = try JSONDecoder().decode(
			[LocalFileLocation].self,
			from: Data(contentsOf: persistenceURL)
		)
		XCTAssertEqual(persisted.single?.displayName, "Workspace")
		XCTAssertNotEqual(
			persisted.single?.bookmarkData,
			location.bookmarkData
		)
	}

	func testUnavailableLocationKeepsRecoverableMetadata() async throws {
		let root = makeTemporaryDirectory()
		let codec = RecordingBookmarkCodec(isReachable: false)
		let store = LocalFileLocationStore(
			fileURL: root.appendingPathComponent("locations.json"),
			bookmarkCodec: codec
		)
		let selectedURL = root.appendingPathComponent("Missing")
		let location = try await store.add(
			url: selectedURL,
			displayName: "Build volume"
		)

		do {
			_ = try await store.access(location.id)
			XCTFail("Expected unavailable location")
		} catch let error as LocalFileLocationError {
			XCTAssertEqual(
				error,
				.unavailable(
					id: location.id,
					displayName: "Build volume"
				)
			)
		}
		let retainedLocation = await store.location(location.id)
		XCTAssertEqual(retainedLocation?.displayName, "Build volume")
	}

	func testSandboxedBookmarkRequiresAnActiveSecurityScope() async throws {
		let root = makeTemporaryDirectory()
		let codec = RecordingBookmarkCodec(
			isReachable: true,
			requiresSecurityScope: true,
			startsSuccessfully: false
		)
		let store = LocalFileLocationStore(
			fileURL: root.appendingPathComponent("locations.json"),
			bookmarkCodec: codec
		)
		let location = try await store.add(
			url: root,
			displayName: "Workspace"
		)
		let grant = try await store.access(location.id)

		do {
			_ = try await grant.withAccess { $0.path }
			XCTFail("Expected denied sandbox access")
		} catch let error as LocalFileLocationError {
			XCTAssertEqual(error, .accessDenied(root.path))
		}
		XCTAssertEqual(codec.startCount, 1)
		XCTAssertEqual(codec.stopCount, 0)
	}

	func testScopedUploadBalancesAccessAroundTransport() async throws {
		let root = makeTemporaryDirectory()
		let localFile = root.appendingPathComponent("payload.txt")
		try Data("payload".utf8).write(to: localFile)
		let access = RecordingResourceAccess(url: localFile)
		let grant = LocalFileAccessGrant(
			url: localFile,
			resourceAccess: access
		)
		let client = ScopedTransferClient()
		let store = FileTransferStore(clientForHost: { _ in client })

		let id = try XCTUnwrap(
			store.enqueueScopedUpload(
				localFiles: [grant],
				remoteDirectory: "/remote",
				host: makeHost()
			).first
		)
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: id)?.status, .completed)
		XCTAssertEqual(access.startCount, 1)
		XCTAssertEqual(access.stopCount, 1)
		let uploadedData = await client.uploadedData
		XCTAssertEqual(uploadedData, Data("payload".utf8))
	}

	func testScopedDownloadBalancesAccessThroughAtomicPublish()
		async throws {
		let root = makeTemporaryDirectory()
		let access = RecordingResourceAccess(url: root)
		let grant = LocalFileAccessGrant(
			url: root,
			resourceAccess: access
		)
		let client = ScopedTransferClient(
			downloadData: Data("downloaded".utf8)
		)
		let store = FileTransferStore(clientForHost: { _ in client })

		let id = try XCTUnwrap(
			store.enqueueScopedDownload(
				remotePaths: ["/remote/report.txt"],
				localDirectory: grant,
				host: makeHost()
			).first
		)
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: id)?.status, .completed)
		XCTAssertEqual(access.startCount, 1)
		XCTAssertEqual(access.stopCount, 1)
		XCTAssertEqual(
			try Data(
				contentsOf: root.appendingPathComponent("report.txt")
			),
			Data("downloaded".utf8)
		)
	}

	func testDescendantAllowsMacFileNamesButRejectsTraversal() async throws {
		let root = makeTemporaryDirectory()
		let outside = makeTemporaryDirectory()
		try FileManager.default.createSymbolicLink(
			at: root.appendingPathComponent("escape"),
			withDestinationURL: outside
		)
		let grant = LocalFileAccessGrant(
			url: root,
			resourceAccess: RecordingResourceAccess(url: root)
		)

		let macFileName = try grant.descendant(
			relativePath: #"reports\archive.txt"#
		)

		XCTAssertEqual(
			macFileName.url.lastPathComponent,
			#"reports\archive.txt"#
		)
		XCTAssertThrowsError(
			try grant.descendant(relativePath: "../outside.txt")
		) { error in
			XCTAssertEqual(
				error as? LocalFileLocationError,
				.invalidRelativePath("../outside.txt")
			)
		}
		let escaped = try grant.descendant(
			relativePath: "escape/outside.txt"
		)
		do {
			_ = try await escaped.withAccess { $0.path }
			XCTFail("Expected the symlink escape to be rejected")
		} catch let error as LocalFileLocationError {
			guard case .invalidRelativePath = error else {
				return XCTFail("Unexpected error: \(error)")
			}
		}
	}

	func testScopedUploadNeverUsesSymlinkOutsideAuthorizedRoot() async throws {
		let root = makeTemporaryDirectory()
		let outside = makeTemporaryDirectory()
		let outsideFile = outside.appendingPathComponent("secret.txt")
		try Data("secret".utf8).write(to: outsideFile)
		try FileManager.default.createSymbolicLink(
			at: root.appendingPathComponent("payload.txt"),
			withDestinationURL: outsideFile
		)
		let rootGrant = LocalFileAccessGrant(
			url: root,
			resourceAccess: RecordingResourceAccess(url: root)
		)
		let escapedGrant = try rootGrant.descendant(
			relativePath: "payload.txt"
		)
		let client = ScopedTransferClient()
		let store = FileTransferStore(clientForHost: { _ in client })

		let id = try XCTUnwrap(
			store.enqueueScopedUpload(
				localFiles: [escapedGrant],
				remoteDirectory: "/remote",
				host: makeHost()
			).first
		)
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: id)?.status, .failed)
		guard case .localIO = store.task(id: id)?.failure else {
			return XCTFail("Expected a local path validation failure")
		}
		let uploadedData = await client.uploadedData
		XCTAssertNil(uploadedData)
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

	private func makeTemporaryDirectory() -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent(
				"caterm-location-test-\(UUID().uuidString)",
				isDirectory: true
			)
		try? FileManager.default.createDirectory(
			at: url,
			withIntermediateDirectories: false
		)
		addTeardownBlock {
			try? FileManager.default.removeItem(at: url)
		}
		return url
	}
}

private final class RecordingBookmarkCodec:
	SecurityScopedBookmarkCoding, @unchecked Sendable {
	private let lock = NSLock()
	private var remainingStaleResolutions: Int
	private let reachable: Bool
	private var creationCount = 0
	private var starts = 0
	private var stops = 0
	let requiresSecurityScope: Bool
	private let startsSuccessfully: Bool

	init(
		staleResolutions: Int = 0,
		isReachable: Bool = true,
		requiresSecurityScope: Bool = false,
		startsSuccessfully: Bool = true
	) {
		remainingStaleResolutions = staleResolutions
		reachable = isReachable
		self.requiresSecurityScope = requiresSecurityScope
		self.startsSuccessfully = startsSuccessfully
	}

	var bookmarkCreationCount: Int {
		lock.withLock { creationCount }
	}

	var startCount: Int {
		lock.withLock { starts }
	}

	var stopCount: Int {
		lock.withLock { stops }
	}

	func createBookmark(for url: URL) throws -> Data {
		let current = lock.withLock {
			creationCount += 1
			return creationCount
		}
		return Data("\(url.path)#\(current)".utf8)
	}

	func resolveBookmark(
		_ data: Data
	) throws -> SecurityScopedBookmarkResolution {
		let encoded = String(decoding: data, as: UTF8.self)
		let path = encoded.split(separator: "#", maxSplits: 1).first
			.map(String.init) ?? encoded
		let stale = lock.withLock {
			guard remainingStaleResolutions > 0 else { return false }
			remainingStaleResolutions -= 1
			return true
		}
		return SecurityScopedBookmarkResolution(
			url: URL(fileURLWithPath: path),
			isStale: stale
		)
	}

	func startAccessing(_ url: URL) -> Bool {
		lock.withLock { starts += 1 }
		return startsSuccessfully
	}

	func stopAccessing(_ url: URL) {
		lock.withLock { stops += 1 }
	}

	func isReachable(_ url: URL) -> Bool {
		reachable
	}
}

private final class RecordingResourceAccess:
	LocalFileResourceAccessing, @unchecked Sendable {
	let url: URL
	private let lock = NSLock()
	private var starts = 0
	private var stops = 0

	init(url: URL) {
		self.url = url
	}

	var startCount: Int {
		lock.withLock { starts }
	}

	var stopCount: Int {
		lock.withLock { stops }
	}

	func startAccessing() throws {
		lock.withLock { starts += 1 }
	}

	func stopAccessing() {
		lock.withLock { stops += 1 }
	}
}

private actor ScopedTransferClient: RemoteFileClient {
	private(set) var uploadedData: Data?
	private let downloadData: Data

	init(downloadData: Data = Data()) {
		self.downloadData = downloadData
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
		replaceExisting: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		uploadedData = try Data(contentsOf: localURL)
		return RemoteFileTransferResult(
			bytesTransferred: Int64(uploadedData?.count ?? 0)
		)
	}

	func download(
		remotePath: String,
		localURL: URL,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		try downloadData.write(to: localURL)
		return RemoteFileTransferResult(
			bytesTransferred: Int64(downloadData.count)
		)
	}
}

private extension Collection {
	var single: Element? {
		count == 1 ? first : nil
	}
}
