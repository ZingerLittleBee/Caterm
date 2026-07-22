import FileTransferStore
import SSHCommandBuilder
@testable import CatermMobile
import XCTest

final class MobileFileBrowserModelTests: XCTestCase {
	func testRemoteFileNameRejectsAmbiguousAndInvalidNames() throws {
		for name in ["", " notes", "notes ", ".", "..", "a/b", "a\0b", "a\nb"] {
			XCTAssertThrowsError(try MobileRemoteFileName(name), "Expected \(name.debugDescription) to fail")
		}
		XCTAssertNoThrow(try MobileRemoteFileName("release notes"))
		XCTAssertThrowsError(try MobileRemoteFileName(String(repeating: "é", count: 128)))
	}

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
	func testCreateFolderUsesCurrentPathAndRefreshesListing() async {
		let client = MutationMobileRemoteFileSession(entries: [])
		let controller = MobileFileBrowserController(factory: .init { _ in client })
		let host = Self.host()
		controller.selectedHostID = host.id
		await controller.refresh(host: host)
		let context = Self.actionContext(controller: controller, host: host)

		await controller.createFolder(named: "archive", context: context)

		let operations = await client.operations()
		XCTAssertEqual(operations, [.createDirectory("~/archive")])
		XCTAssertEqual(controller.entries.map(\.name), ["archive"])
		XCTAssertNil(controller.mutation)
		XCTAssertNil(controller.mutationFailure)
	}

	func testRenameKeepsOperationInParentScopeAndRefreshesListing() async {
		let entry = Self.entry(name: "draft.txt", isDirectory: false)
		let client = MutationMobileRemoteFileSession(entries: [entry])
		let controller = MobileFileBrowserController(
			factory: .init { _ in client },
			entries: [entry]
		)
		let host = Self.host()
		controller.selectedHostID = host.id
		let context = Self.actionContext(controller: controller, host: host)

		await controller.rename(entry, to: "final.txt", context: context)

		let operations = await client.operations()
		XCTAssertEqual(
			operations,
			[.rename(from: "~/draft.txt", to: "~/final.txt")]
		)
		XCTAssertEqual(controller.entries.map(\.name), ["final.txt"])
	}

	func testDeletePassesExactTargetTypeAndRefreshesListing() async {
		let entry = Self.entry(name: "archive", isDirectory: true)
		let client = MutationMobileRemoteFileSession(entries: [entry])
		let controller = MobileFileBrowserController(
			factory: .init { _ in client },
			entries: [entry]
		)
		let host = Self.host()
		controller.selectedHostID = host.id
		let context = Self.actionContext(controller: controller, host: host)

		await controller.delete(entry, context: context)

		let operations = await client.operations()
		XCTAssertEqual(
			operations,
			[.delete(path: "~/archive", isDirectory: true)]
		)
		XCTAssertTrue(controller.entries.isEmpty)
	}

	func testStaleEntryDoesNotReachTransport() async {
		let visible = Self.entry(name: "visible.txt", isDirectory: false)
		let stale = Self.entry(name: "stale.txt", isDirectory: false)
		let client = MutationMobileRemoteFileSession(entries: [visible])
		let controller = MobileFileBrowserController(
			factory: .init { _ in client },
			entries: [visible]
		)
		let host = Self.host()
		controller.selectedHostID = host.id
		let context = Self.actionContext(controller: controller, host: host)

		await controller.delete(stale, context: context)

		let operations = await client.operations()
		XCTAssertEqual(operations, [])
		XCTAssertEqual(controller.entries, [visible])
		XCTAssertEqual(
			controller.mutationFailure?.title,
			"Couldn’t Delete File"
		)
		XCTAssertEqual(controller.mutationFailure?.canRetry, false)
	}

	func testCapturedPromptContextCannotTargetSamePathOnAnotherHost() async {
		let entry = Self.entry(name: "visible.txt", isDirectory: false)
		let client = MutationMobileRemoteFileSession(entries: [entry])
		let controller = MobileFileBrowserController(
			factory: .init { _ in client },
			entries: [entry]
		)
		let visibleHost = Self.host()
		let otherHost = Self.host()
		controller.selectedHostID = visibleHost.id
		let capturedContext = Self.actionContext(
			controller: controller,
			host: visibleHost
		)
		controller.selectedHostID = otherHost.id

		await controller.delete(entry, context: capturedContext)

		let operations = await client.operations()
		XCTAssertEqual(operations, [])
		XCTAssertEqual(controller.selectedHostID, otherHost.id)
		XCTAssertEqual(controller.entries, [entry])
		XCTAssertEqual(controller.mutationFailure?.canRetry, false)
	}

	func testPathChangeCancelsInFlightMutationWithoutPublishingStaleResults() async {
		let child = Self.entry(name: "child", isDirectory: true)
		let fresh = Self.entry(name: "fresh.txt", isDirectory: false)
		let client = SuspendedMutationMobileRemoteFileSession(
			childListing: [fresh]
		)
		let controller = MobileFileBrowserController(
			factory: .init { _ in client },
			entries: [child]
		)
		let host = Self.host()
		controller.selectedHostID = host.id

		let mutation = Task {
			let context = Self.actionContext(controller: controller, host: host)
			await controller.createFolder(named: "stale-folder", context: context)
		}
		await client.waitForMutation()
		controller.activate(child, host: host)
		try? await Task.sleep(for: .milliseconds(20))
		let loadedBeforeRelease = await client.loadedBeforeDisconnect()
		XCTAssertFalse(loadedBeforeRelease)
		await client.releaseMutation()
		await mutation.value
		for _ in 0..<100 where controller.entries != [fresh] {
			try? await Task.sleep(for: .milliseconds(10))
		}

		XCTAssertEqual(controller.model.path, "~/child")
		XCTAssertEqual(controller.entries, [fresh])
		XCTAssertEqual(controller.state, .loaded)
		XCTAssertNil(controller.mutation)
		XCTAssertNil(controller.mutationFailure)
		let operations = await client.operations()
		XCTAssertEqual(operations, [.createDirectory("~/stale-folder")])
		let reusedWhileClosing = await client.loadedBeforeDisconnect()
		XCTAssertFalse(reusedWhileClosing)
	}

	func testTransportFailureRefreshesInsteadOfRepeatingMutation() async {
		let entry = Self.entry(name: "archive", isDirectory: true)
		let client = MutationMobileRemoteFileSession(
			entries: [entry],
			mutationError: RemoteFileError.transport(message: "Response lost")
		)
		let controller = MobileFileBrowserController(
			factory: .init { _ in client },
			entries: [entry]
		)
		let host = Self.host()
		controller.selectedHostID = host.id
		let context = Self.actionContext(controller: controller, host: host)

		await controller.delete(entry, context: context)
		XCTAssertEqual(controller.mutationFailure?.recoveryActionTitle, "Refresh")
		await controller.retryMutation(host: host)

		let operations = await client.operations()
		XCTAssertEqual(
			operations,
			[.delete(path: "~/archive", isDirectory: true)]
		)
		XCTAssertEqual(controller.entries, [entry])
		XCTAssertNil(controller.mutationFailure)
	}

	func testOverlappingMutationIsRejectedUntilActiveMutationFinishes() async {
		let client = SuspendedMutationMobileRemoteFileSession(childListing: [])
		let controller = MobileFileBrowserController(
			factory: .init { _ in client },
			entries: [Self.entry(name: "visible", isDirectory: true)]
		)
		let host = Self.host()
		controller.selectedHostID = host.id
		let context = Self.actionContext(controller: controller, host: host)

		let first = Task {
			await controller.createFolder(named: "first", context: context)
		}
		await client.waitForMutation()
		await controller.createFolder(named: "second", context: context)

		let operationsWhileSuspended = await client.operations()
		XCTAssertEqual(operationsWhileSuspended, [.createDirectory("~/first")])
		await client.releaseMutation()
		await first.value
	}

	func testUnknownEntryIsNeverGuessedAsAFileForDeletion() async {
		let entry = RemoteEntry(
			name: "mystery",
			type: .unknown,
			size: nil,
			mtime: nil,
			mode: nil,
			canonicalPath: "/home/caterm/mystery"
		)
		let client = MutationMobileRemoteFileSession(entries: [entry])
		let controller = MobileFileBrowserController(
			factory: .init { _ in client },
			entries: [entry]
		)
		let host = Self.host()
		controller.selectedHostID = host.id
		let context = Self.actionContext(controller: controller, host: host)

		await controller.delete(entry, context: context)

		let operations = await client.operations()
		XCTAssertEqual(operations, [])
		XCTAssertEqual(controller.entries, [entry])
		XCTAssertEqual(
			controller.mutationFailure?.message,
			"Caterm cannot determine whether this remote item is a file or folder."
		)
	}

	func testMutationFailurePreservesListingAndOffersContextualRecovery() async {
		let entry = Self.entry(name: "archive", isDirectory: true)
		let client = MutationMobileRemoteFileSession(
			entries: [entry],
			mutationError: RemoteFileError.directoryNotEmpty(path: "~/archive")
		)
		let controller = MobileFileBrowserController(
			factory: .init { _ in client },
			entries: [entry]
		)
		let host = Self.host()
		controller.selectedHostID = host.id
		let context = Self.actionContext(controller: controller, host: host)

		await controller.delete(entry, context: context)

		XCTAssertEqual(controller.entries, [entry])
		XCTAssertEqual(controller.state, .loaded)
		XCTAssertEqual(controller.mutationFailure?.title, "Couldn’t Delete Folder")
		XCTAssertEqual(
			controller.mutationFailure?.recoverySuggestion,
			"Delete the folder’s contents first."
		)
	}

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

	private static func entry(name: String, isDirectory: Bool) -> RemoteEntry {
		RemoteEntry(
			name: name,
			isDirectory: isDirectory,
			size: 0,
			mtime: nil,
			mode: isDirectory ? 0o755 : 0o644,
			canonicalPath: "/home/caterm/\(name)"
		)
	}

	private static func actionContext(
		controller: MobileFileBrowserController,
		host: SSHHost,
		file: StaticString = #filePath,
		line: UInt = #line
	) -> MobileFileActionContext {
		guard let context = controller.actionContext(host: host) else {
			XCTFail("Expected a loaded file action context", file: file, line: line)
			return MobileFileActionContext(host: host, parentPath: "~")
		}
		return context
	}
}

private enum RecordedMobileFileOperation: Equatable, Sendable {
	case createDirectory(String)
	case rename(from: String, to: String)
	case delete(path: String, isDirectory: Bool)
}

private actor MutationMobileRemoteFileSession: MobileRemoteFileSession {
	private var entries: [RemoteEntry]
	private var recorded: [RecordedMobileFileOperation] = []
	private let mutationError: RemoteFileError?

	init(entries: [RemoteEntry], mutationError: RemoteFileError? = nil) {
		self.entries = entries
		self.mutationError = mutationError
	}

	func list(_ path: String) async throws -> [RemoteEntry] { entries }
	func stat(_ path: String) async throws -> RemoteEntry? { nil }

	func createDirectory(_ path: String) async throws {
		recorded.append(.createDirectory(path))
		if let mutationError { throw mutationError }
		let name = (path as NSString).lastPathComponent
		entries.append(RemoteEntry(
			name: name,
			isDirectory: true,
			size: 0,
			mtime: nil,
			mode: 0o755,
			canonicalPath: "/home/caterm/\(name)"
		))
	}

	func rename(from source: String, to destination: String) async throws {
		recorded.append(.rename(from: source, to: destination))
		if let mutationError { throw mutationError }
		let sourceName = (source as NSString).lastPathComponent
		let destinationName = (destination as NSString).lastPathComponent
		guard let index = entries.firstIndex(where: { $0.name == sourceName }) else {
			throw RemoteFileError.notFound(path: source)
		}
		let old = entries.remove(at: index)
		entries.append(RemoteEntry(
			name: destinationName,
			type: old.type,
			size: old.size,
			mtime: old.mtime,
			mode: old.mode,
			canonicalPath: "/home/caterm/\(destinationName)"
		))
	}

	func delete(_ path: String, isDirectory: Bool) async throws {
		recorded.append(.delete(path: path, isDirectory: isDirectory))
		if let mutationError { throw mutationError }
		let name = (path as NSString).lastPathComponent
		entries.removeAll { $0.name == name }
	}

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

	func disconnect() async {}
	func operations() -> [RecordedMobileFileOperation] { recorded }
}

private actor SuspendedMutationMobileRemoteFileSession: MobileRemoteFileSession {
	private let childListing: [RemoteEntry]
	private var recorded: [RecordedMobileFileOperation] = []
	private var mutationEntered = false
	private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
	private var mutationContinuation: CheckedContinuation<Void, Never>?
	private var disconnected = false
	private var didLoadBeforeDisconnect = false

	init(childListing: [RemoteEntry]) {
		self.childListing = childListing
	}

	func list(_ path: String) async throws -> [RemoteEntry] {
		if !disconnected { didLoadBeforeDisconnect = true }
		return path == "~/child" ? childListing : []
	}

	func stat(_ path: String) async throws -> RemoteEntry? { nil }

	func createDirectory(_ path: String) async throws {
		recorded.append(.createDirectory(path))
		mutationEntered = true
		let waiters = mutationWaiters
		mutationWaiters.removeAll()
		for waiter in waiters { waiter.resume() }
		await withCheckedContinuation { continuation in
			mutationContinuation = continuation
		}
	}

	func waitForMutation() async {
		if mutationEntered { return }
		await withCheckedContinuation { continuation in
			mutationWaiters.append(continuation)
		}
	}

	func releaseMutation() {
		mutationContinuation?.resume()
		mutationContinuation = nil
	}

	func rename(from: String, to: String) async throws {}
	func delete(_ path: String, isDirectory: Bool) async throws {}

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

	func disconnect() async { disconnected = true }
	func operations() -> [RecordedMobileFileOperation] { recorded }
	func loadedBeforeDisconnect() -> Bool { didLoadBeforeDisconnect }
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
