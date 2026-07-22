import XCTest
@testable import FileTransferStore
import SFTPCommandBuilder
import SSHCommandBuilder

final class RemoteFileSystemTests: XCTestCase {
	final class FakeSFTPRunner: SFTPRunner, @unchecked Sendable {
		var nextStdout: String = ""
		var nextExit: Int32 = 0
		var scriptedResults: [(String, Int32)] = []
		var error: Error?
		var lastInvocation: SFTPInvocation?
		var invocations: [SFTPInvocation] = []
		func run(_ inv: SFTPInvocation) async throws -> (stdout: String, exit: Int32) {
			if let error { throw error }
			lastInvocation = inv
			invocations.append(inv)
			if !scriptedResults.isEmpty {
				return scriptedResults.removeFirst()
			}
			return (nextStdout, nextExit)
		}
	}
	final class AlwaysAlive: ControlMasterLiveness, @unchecked Sendable {
		func isAlive(hostId: UUID) async -> Bool { true }
	}
	final class NeverAlive: ControlMasterLiveness, @unchecked Sendable {
		func isAlive(hostId: UUID) async -> Bool { false }
	}

	func makeHost() -> SSHHost {
		SSHHost(id: UUID(), name: "x", hostname: "h", port: 22, username: "u", credential: .agent)
	}
	func makeCreds() -> SFTPCredentials {
		SFTPCredentials(knownHostsCaterm: URL(fileURLWithPath: "/k1"),
		                knownHostsUser: URL(fileURLWithPath: "/k2"),
		                strictHostKeyChecking: .acceptNew)
	}

	func testListThrowsWhenSessionGone() async {
		let fs = RemoteFileSystem(host: makeHost(),
		                          controlPath: URL(fileURLWithPath: "/sock"),
		                          credentials: makeCreds(),
		                          runner: FakeSFTPRunner(),
		                          liveness: NeverAlive())
		do {
			_ = try await fs.list("/")
			XCTFail("expected throw")
		} catch RemoteFileError.sessionUnavailable {
			// expected
		} catch {
			XCTFail("got \(error)")
		}
	}

	func testListParsesLsLaOutput() async throws {
		let runner = FakeSFTPRunner()
		runner.nextStdout = """
		sftp> cd "/etc"
		sftp> ls -la
		drwxr-xr-x  10 root  wheel   320 Apr 30 10:00 .
		drwxr-xr-x  20 root  wheel   640 Apr  1 12:00 ..
		-rw-r--r--   1 root  wheel  1234 Apr 30 09:00 hosts
		sftp> exit
		"""
		let fs = RemoteFileSystem(host: makeHost(),
		                          controlPath: URL(fileURLWithPath: "/sock"),
		                          credentials: makeCreds(),
		                          runner: runner,
		                          liveness: AlwaysAlive())
		let entries = try await fs.list("/etc")
		XCTAssertEqual(entries.count, 1)
		XCTAssertEqual(entries[0].name, "hosts")
		XCTAssertFalse(entries[0].isDirectory)
		XCTAssertEqual(entries[0].size, 1234)
	}

	func testMkdirInvokesSubprocessAndPropagatesFailure() async {
		let runner = FakeSFTPRunner()
		runner.nextStdout = "permission denied\n"
		runner.nextExit = 1
		let fs = RemoteFileSystem(host: makeHost(),
		                          controlPath: URL(fileURLWithPath: "/sock"),
		                          credentials: makeCreds(),
		                          runner: runner,
		                          liveness: AlwaysAlive())
		do {
			try await fs.mkdir("/srv/new")
			XCTFail()
		} catch let RemoteFileError.permissionDenied(message) {
			XCTAssertTrue(message.contains("permission denied"))
		} catch {
			XCTFail("got \(error)")
		}
	}

	func testPublicClientContractCoversListingStatMutationsAndTransfers() async throws {
		let listing = "-rw-r--r-- 1 user staff 4 Jul 22 10:00 file.txt\n"
		let runner = FakeSFTPRunner()
		runner.scriptedResults = [
			(listing, 0),
			(listing, 0),
			("", 0),
			("", 0),
			("", 0),
			("", 0),
			(listing, 0),
			("", 0),
		]
		let client: any RemoteFileClient = RemoteFileSystem(
			host: makeHost(),
			controlPath: URL(fileURLWithPath: "/sock"),
			credentials: makeCreds(),
			runner: runner,
			liveness: AlwaysAlive()
		)
		let local = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-client-contract-\(UUID().uuidString)")
		try Data("data".utf8).write(to: local)
		defer { try? FileManager.default.removeItem(at: local) }
		let progress = ProgressRecorder()

		let entries = try await client.list("/remote")
		let metadata = try await client.stat("/remote/file.txt")
		XCTAssertEqual(entries.map(\.name), ["file.txt"])
		XCTAssertEqual(metadata?.size, 4)
		try await client.createDirectory("/remote/new")
		try await client.rename(from: "/remote/new", to: "/remote/renamed")
		try await client.delete("/remote/renamed", isDirectory: true)
		let upload = try await client.upload(
			localURL: local,
			remotePath: "/remote/file.txt",
			isDirectory: false,
			resume: false,
			progress: { update in await progress.append(update) }
		)
		let download = try await client.download(
			remotePath: "/remote/file.txt",
			localURL: local.appendingPathExtension("download"),
			isDirectory: false,
			resume: false,
			progress: { update in await progress.append(update) }
		)
		let progressUpdates = await progress.values()

		XCTAssertEqual(upload.bytesTransferred, 4)
		XCTAssertEqual(download.bytesTransferred, 4)
		XCTAssertEqual(progressUpdates.last?.bytesTransferred, 4)
		let scripts = runner.invocations.map(\.scriptStdin)
		XCTAssertTrue(scripts.contains { $0.hasPrefix("mkdir") })
		XCTAssertTrue(scripts.contains { $0.hasPrefix("rename") })
		XCTAssertTrue(scripts.contains { $0.hasPrefix("rmdir") })
		XCTAssertTrue(scripts.contains { $0.hasPrefix("put") })
		XCTAssertTrue(scripts.contains { $0.hasPrefix("get") })
	}

	func testPublicClientMapsRunnerCancellationToTypedFailure() async {
		let runner = FakeSFTPRunner()
		runner.error = CancellationError()
		let client: any RemoteFileClient = RemoteFileSystem(
			host: makeHost(),
			controlPath: URL(fileURLWithPath: "/sock"),
			credentials: makeCreds(),
			runner: runner,
			liveness: AlwaysAlive()
		)

		do {
			_ = try await client.list("/")
			XCTFail("Expected cancellation")
		} catch RemoteFileError.cancelled {
			// Expected.
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}
}

private actor ProgressRecorder {
	private var updates: [TransferProgress] = []

	func append(_ update: TransferProgress) {
		updates.append(update)
	}

	func values() -> [TransferProgress] {
		updates
	}
}
