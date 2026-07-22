import FileTransferStore
import SSHCommandBuilder
@testable import CatermMobile
import XCTest

final class MobileFileBrowserModelTests: XCTestCase {
	func testFolderActivationAppendsChildPathUnderHomeRoot() {
		var model = MobileFileBrowserModel(path: "~")
		let entry = RemoteEntry(name: "logs", isDirectory: true, size: 0, mtime: nil, mode: 0o755)

		model.activate(entry)

		XCTAssertEqual(model.path, "~/logs")
	}

	func testFolderActivationAppendsChildPathUnderFilesystemRoot() {
		var model = MobileFileBrowserModel(path: "/")
		let entry = RemoteEntry(name: "var", isDirectory: true, size: 0, mtime: nil, mode: 0o755)

		model.activate(entry)

		XCTAssertEqual(model.path, "/var")
	}

	func testGoUpPreservesHomeAndFilesystemRoots() {
		var home = MobileFileBrowserModel(path: "~")
		var root = MobileFileBrowserModel(path: "/")

		home.goUp()
		root.goUp()

		XCTAssertEqual(home.path, "~")
		XCTAssertEqual(root.path, "/")
	}

	func testGoUpMovesToParentPath() {
		var homeChild = MobileFileBrowserModel(path: "~/logs/archive")
		var rootChild = MobileFileBrowserModel(path: "/var/log")

		homeChild.goUp()
		rootChild.goUp()

		XCTAssertEqual(homeChild.path, "~/logs")
		XCTAssertEqual(rootChild.path, "/var")
	}

	func testFileActivationStagesDownloadSheet() {
		var model = MobileFileBrowserModel(path: "~/logs")
		let entry = RemoteEntry(name: "app.log", isDirectory: false, size: 123, mtime: nil, mode: 0o644)

		model.activate(entry)

		XCTAssertEqual(model.presentation, .download(path: "~/logs/app.log"))
	}

	func testDeleteAndRenameStageExplicitPresentationState() {
		var model = MobileFileBrowserModel(path: "/var")
		let entry = RemoteEntry(name: "log", isDirectory: true, size: 0, mtime: nil, mode: 0o755)

		model.requestDelete(entry)
		XCTAssertEqual(model.presentation, .confirmDelete(path: "/var/log", isDirectory: true))

		model.requestRename(entry)
		XCTAssertEqual(model.presentation, .rename(path: "/var/log", currentName: "log"))
	}
}

@MainActor
final class MobileFileBrowserControllerTests: XCTestCase {
	func testRefreshPublishesRealEntriesAndCanonicalPaths() async throws {
		let expected = RemoteEntry(
			name: "logs",
			isDirectory: true,
			size: 0,
			mtime: nil,
			mode: 0o755,
			canonicalPath: "/home/caterm/logs"
		)
		let client = StubMobileRemoteFileSession(result: .success([expected]))
		let controller = MobileFileBrowserController(factory: .init { _ in client })
		let host = Self.host()
		controller.selectedHostID = host.id

		await controller.refresh(host: host)

		XCTAssertEqual(controller.state, .loaded)
		XCTAssertEqual(controller.entries, [expected])
		let requestedPaths = await client.requestedPaths()
		XCTAssertEqual(requestedPaths, ["~"])
	}

	func testPermissionFailureKeepsSessionAvailableForRetry() async {
		let client = StubMobileRemoteFileSession(
			result: .failure(RemoteFileError.permissionDenied(message: "Denied"))
		)
		let controller = MobileFileBrowserController(factory: .init { _ in client })
		let host = Self.host()
		controller.selectedHostID = host.id

		await controller.refresh(host: host)

		XCTAssertEqual(controller.state, .permissionDenied("Denied"))
		let disconnectCount = await client.disconnectCount()
		XCTAssertEqual(disconnectCount, 0)
	}

	func testChangedHostKeyBecomesTypedTrustFailureAndDropsSFTPSession() async {
		let client = StubMobileRemoteFileSession(
			result: .failure(RemoteFileError.hostKeyChanged(endpoint: "box:22"))
		)
		let controller = MobileFileBrowserController(factory: .init { _ in client })
		let host = Self.host()
		controller.selectedHostID = host.id

		await controller.refresh(host: host)

		XCTAssertEqual(
			controller.state,
			.trustFailure("The SSH host key changed for box:22.")
		)
	}

	func testCancelledRefreshCannotOverwriteNewerPath() async {
		let stale = RemoteEntry(
			name: "stale.txt",
			isDirectory: false,
			size: 1,
			mtime: nil,
			mode: 0o644
		)
		let fresh = RemoteEntry(
			name: "fresh.txt",
			isDirectory: false,
			size: 2,
			mtime: nil,
			mode: 0o644
		)
		let client = PathAwareMobileRemoteFileSession(stale: stale, fresh: fresh)
		let controller = MobileFileBrowserController(factory: .init { _ in client })
		let host = Self.host()
		controller.selectedHostID = host.id

		let firstRefresh = Task { await controller.refresh(host: host) }
		await client.waitForFirstRequest()
		controller.activate(
			RemoteEntry(
				name: "logs",
				isDirectory: true,
				size: 0,
				mtime: nil,
				mode: 0o755
			),
			host: host
		)
		await firstRefresh.value
		for _ in 0..<100 where controller.entries != [fresh] {
			try? await Task.sleep(for: .milliseconds(10))
		}

		XCTAssertEqual(controller.model.path, "~/logs")
		XCTAssertEqual(controller.entries, [fresh])
		XCTAssertEqual(controller.state, .loaded)
		let requestedPaths = await client.requestedPaths()
		XCTAssertEqual(requestedPaths, ["~", "~/logs"])
	}

	private static func host() -> SSHHost {
		SSHHost(
			name: "Box",
			hostname: "box",
			username: "caterm",
			credential: .password
		)
	}
}

private actor StubMobileRemoteFileSession: MobileRemoteFileSession {
	private let result: Result<[RemoteEntry], Error>
	private var paths: [String] = []
	private var disconnects = 0

	init(result: Result<[RemoteEntry], Error>) {
		self.result = result
	}

	func list(_ path: String) async throws -> [RemoteEntry] {
		paths.append(path)
		return try result.get()
	}

	func stat(_ path: String) async throws -> RemoteEntry? { nil }

	func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		throw RemoteFileError.unsupported(operation: "upload")
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

	func createDirectory(_ path: String) async throws {}
	func rename(from: String, to: String) async throws {}
	func delete(_ path: String, isDirectory: Bool) async throws {}

	func disconnect() async { disconnects += 1 }

	func requestedPaths() -> [String] { paths }
	func disconnectCount() -> Int { disconnects }
}

private actor PathAwareMobileRemoteFileSession: MobileRemoteFileSession {
	private let stale: RemoteEntry
	private let fresh: RemoteEntry
	private var paths: [String] = []
	private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []

	init(stale: RemoteEntry, fresh: RemoteEntry) {
		self.stale = stale
		self.fresh = fresh
	}

	func list(_ path: String) async throws -> [RemoteEntry] {
		paths.append(path)
		if paths.count == 1 {
			let waiters = firstRequestWaiters
			firstRequestWaiters.removeAll()
			for waiter in waiters { waiter.resume() }
			try? await Task.sleep(for: .milliseconds(50))
			return [stale]
		}
		return [fresh]
	}

	func waitForFirstRequest() async {
		if !paths.isEmpty { return }
		await withCheckedContinuation { continuation in
			firstRequestWaiters.append(continuation)
		}
	}

	func requestedPaths() -> [String] { paths }
	func disconnect() async {}
	func stat(_ path: String) async throws -> RemoteEntry? { nil }

	func upload(
		localURL: URL,
		remotePath: String,
		isDirectory: Bool,
		resume: Bool,
		progress: @escaping TransferProgressHandler
	) async throws -> RemoteFileTransferResult {
		throw RemoteFileError.unsupported(operation: "upload")
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

	func createDirectory(_ path: String) async throws {}
	func rename(from: String, to: String) async throws {}
	func delete(_ path: String, isDirectory: Bool) async throws {}
}
