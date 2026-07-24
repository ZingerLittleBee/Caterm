import XCTest
@testable import FileTransferStore
import SFTPCommandBuilder
import SSHCommandBuilder

@MainActor
final class FileTransferStoreTests: XCTestCase {
	final class ScriptedRunner: SFTPRunner, @unchecked Sendable {
		var script: [(stdout: String, exit: Int32)] = []
		var calls: [SFTPInvocation] = []
		func run(_ inv: SFTPInvocation) async throws -> (stdout: String, exit: Int32) {
			calls.append(inv)
			return script.isEmpty ? ("", 0) : script.removeFirst()
		}
	}
	final class AlwaysAlive: ControlMasterLiveness, @unchecked Sendable {
		func isAlive(hostId: UUID) async -> Bool { true }
	}
	final class NeverAlive: ControlMasterLiveness, @unchecked Sendable {
		func isAlive(hostId: UUID) async -> Bool { false }
	}

	func makeHost(_ id: UUID = UUID()) -> SSHHost {
		SSHHost(id: id, name: "x", hostname: "h", port: 22, username: "u", credential: .agent)
	}

	func makeUploadFiles(_ names: [String]) throws -> [URL] {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-transfer-store-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true
		)
		addTeardownBlock {
			try? FileManager.default.removeItem(at: directory)
		}
		return try names.map { name in
			let url = directory.appendingPathComponent(name)
			try Data(name.utf8).write(to: url)
			return url
		}
	}

	func testSerialFifoForOneHost() async throws {
		let runner = ScriptedRunner()
		runner.script = [("", 0), ("", 0), ("", 0)]
		let store = FileTransferStore(
			controlPathFor: { _ in URL(fileURLWithPath: "/sock") },
			credentialsFor: { _ in defaultCreds() },
			runner: runner,
			liveness: AlwaysAlive()
		)
		let host = makeHost()
		let localFiles = try makeUploadFiles(["a", "b", "c"])
		let ids = store.enqueueUpload(
			localPaths: localFiles,
			remoteDir: "/srv", host: host
		)
		XCTAssertEqual(ids.count, 3)
		try await store.waitIdle()
		let kinds = runner.calls
			.map(\.scriptStdin)
			.filter { $0.hasPrefix("put") }
			.map { String($0.prefix(3)) }
		XCTAssertEqual(kinds, ["put", "put", "put"])
		for id in ids {
			XCTAssertEqual(store.task(id: id)?.status, .completed)
		}
	}

	func testTwoHostsRunInParallel() async throws {
		let runner = ScriptedRunner()
		let store = FileTransferStore(
			controlPathFor: { _ in URL(fileURLWithPath: "/sock") },
			credentialsFor: { _ in defaultCreds() },
			runner: runner,
			liveness: AlwaysAlive()
		)
		let h1 = makeHost(); let h2 = makeHost()
		let localFiles = try makeUploadFiles(["a", "b"])
		_ = store.enqueueUpload(localPaths: [localFiles[0]], remoteDir: "/", host: h1)
		_ = store.enqueueUpload(localPaths: [localFiles[1]], remoteDir: "/", host: h2)
		try await store.waitIdle()
		XCTAssertEqual(
			runner.calls.filter { $0.scriptStdin.hasPrefix("put") }.count,
			2
		)
	}

	func testRetryUsesResumeFlag() async throws {
		let runner = ScriptedRunner()
		runner.script = [("permission denied", 1)]
		let store = FileTransferStore(
			controlPathFor: { _ in URL(fileURLWithPath: "/sock") },
			credentialsFor: { _ in defaultCreds() },
			runner: runner,
			liveness: AlwaysAlive()
		)
		let host = makeHost()
		let localFiles = try makeUploadFiles(["a"])
		let ids = store.enqueueUpload(localPaths: localFiles, remoteDir: "/", host: host)
		try await store.waitIdle()
		XCTAssertEqual(store.task(id: ids[0])?.status, .failed)
		runner.script = [("", 0)]
		store.retry(ids[0])
		try await store.waitIdle()
		XCTAssertEqual(store.task(id: ids[0])?.status, .completed)
		XCTAssertTrue(runner.calls.last!.scriptStdin.hasPrefix("put -pa"))
	}

	func testCancelMidQueueRemovesPending() async throws {
		let runner = ScriptedRunner()
		runner.script = [("", 0), ("", 0)]
		let store = FileTransferStore(
			controlPathFor: { _ in URL(fileURLWithPath: "/sock") },
			credentialsFor: { _ in defaultCreds() },
			runner: runner,
			liveness: AlwaysAlive()
		)
		let host = makeHost()
		let localFiles = try makeUploadFiles(["a", "b", "c"])
		let ids = store.enqueueUpload(
			localPaths: localFiles,
			remoteDir: "/", host: host
		)
		store.cancel(ids[2])
		try await store.waitIdle()
		XCTAssertEqual(store.task(id: ids[0])?.status, .completed)
		XCTAssertEqual(store.task(id: ids[1])?.status, .completed)
		XCTAssertEqual(store.task(id: ids[2])?.status, .cancelled)
	}

	func testDeadControlMasterFailsBeforeInvokingSFTP() async throws {
		let runner = ScriptedRunner()
		let localDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-dead-master-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: localDirectory,
			withIntermediateDirectories: true
		)
		defer { try? FileManager.default.removeItem(at: localDirectory) }
		let store = FileTransferStore(
			controlPathFor: { _ in URL(fileURLWithPath: "/sock") },
			credentialsFor: { _ in defaultCreds() },
			runner: runner,
			liveness: NeverAlive()
		)
		let ids = store.enqueueDownload(
			remotePaths: ["/remote/file"],
			localDir: localDirectory,
			host: makeHost()
		)

		try await store.waitIdle()

		XCTAssertEqual(store.task(id: ids[0])?.status, .failed)
		XCTAssertEqual(store.task(id: ids[0])?.error, "SSH session is no longer available")
		XCTAssertTrue(runner.calls.isEmpty)
	}
}

private func defaultCreds() -> SFTPCredentials {
	SFTPCredentials(knownHostsCaterm: URL(fileURLWithPath: "/k1"),
	                knownHostsUser: URL(fileURLWithPath: "/k2"),
	                strictHostKeyChecking: .acceptNew)
}
