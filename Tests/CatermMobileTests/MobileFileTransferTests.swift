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

		let staged = try await workspace.stageUploads([source])

		let copy = try XCTUnwrap(staged.first)
		XCTAssertEqual(copy.lastPathComponent, "report.txt")
		XCTAssertEqual(try Data(contentsOf: copy), bytes)
		XCTAssertTrue(copy.path.hasPrefix(root.path))
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

	func testCompletedUploadCleanupRemovesOnlyOwnedStagingDirectory() async throws {
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
		let stagedURLs = try await workspace.stageUploads([source])
		let staged = try XCTUnwrap(stagedURLs.first)

		try await workspace.removeCompletedUpload(at: staged)
		try await workspace.removeCompletedUpload(at: source)

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
			_ = try await workspace.stageUploads([file, directory])
			XCTFail("Expected directory upload rejection")
		} catch RemoteFileError.unsupported {
			// Expected.
		}

		let uploads = root.appendingPathComponent("Uploads", isDirectory: true)
		let remaining = try FileManager.default.contentsOfDirectory(
			at: uploads,
			includingPropertiesForKeys: nil
		)
		XCTAssertTrue(remaining.isEmpty)
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
			_ = try await workspace.stageUploads([source])
			XCTFail("Expected staging copy failure")
		} catch RemoteFileError.localIO {
			// Expected.
		}

		let uploads = root.appendingPathComponent("Uploads", isDirectory: true)
		let remaining = try FileManager.default.contentsOfDirectory(
			at: uploads,
			includingPropertiesForKeys: nil
		)
		XCTAssertTrue(remaining.isEmpty)
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
