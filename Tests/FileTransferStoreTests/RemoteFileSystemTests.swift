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
		var onRun: ((SFTPInvocation) throws -> Void)?
		func run(_ inv: SFTPInvocation) async throws -> (stdout: String, exit: Int32) {
			if let error { throw error }
			try onRun?(inv)
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

	func testListPreservesConsecutiveSpacesInFilename() async throws {
		let runner = FakeSFTPRunner()
		runner.nextStdout = "-rw-r--r-- 1 user staff 4 Jul 22 10:00 report  final.txt\n"
		let fs = RemoteFileSystem(
			host: makeHost(),
			controlPath: URL(fileURLWithPath: "/sock"),
			credentials: makeCreds(),
			runner: runner,
			liveness: AlwaysAlive()
		)

		let entries = try await fs.list("/remote")

		XCTAssertEqual(entries.map(\.name), ["report  final.txt"])
		let match = try await fs.stat("/remote/report  final.txt")
		XCTAssertEqual(match?.name, "report  final.txt")
	}

	@MainActor
	func testUploadConflictWithConsecutiveSpacesDoesNotOverwrite() async throws {
		let runner = FakeSFTPRunner()
		runner.nextStdout = "-rw-r--r-- 1 user staff 4 Jul 22 10:00 report  final.txt\n"
		let host = makeHost()
		let client: any RemoteFileClient = RemoteFileSystem(
			host: host,
			controlPath: URL(fileURLWithPath: "/sock"),
			credentials: makeCreds(),
			runner: runner,
			liveness: AlwaysAlive()
		)
		let local = FileManager.default.temporaryDirectory
			.appendingPathComponent("report  final.txt")
		try Data("new".utf8).write(to: local)
		defer { try? FileManager.default.removeItem(at: local) }
		let store = FileTransferStore(clientForHost: { _ in client })

		let id = try XCTUnwrap(store.enqueueUpload(
			localPaths: [local],
			remoteDir: "/remote",
			host: host
		).first)
		try await store.waitIdle()

		XCTAssertEqual(store.task(id: id)?.status, .conflict)
		XCTAssertEqual(runner.invocations.count, 1)
		XCTAssertFalse(runner.invocations[0].scriptStdin.contains("put "))
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
		let workspace = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-client-contract-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: workspace,
			withIntermediateDirectories: true
		)
		defer { try? FileManager.default.removeItem(at: workspace) }
		runner.onRun = { invocation in
			if invocation.scriptStdin.hasPrefix("get") {
				try Data("data".utf8).write(
					to: workspace.appendingPathComponent("download.txt")
				)
			}
		}
		let client: any RemoteFileClient = RemoteFileSystem(
			host: makeHost(),
			controlPath: URL(fileURLWithPath: "/sock"),
			credentials: makeCreds(),
			runner: runner,
			liveness: AlwaysAlive()
		)

		try await RemoteFileClientContract.verifyBehavior(
			client: client,
			workspace: workspace
		)
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

		await RemoteFileClientContract.verifyTypedCancellation(client: client)
	}
}
