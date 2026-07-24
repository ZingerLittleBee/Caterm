import Foundation
import SSHCommandBuilder
@testable import CatermMobileTerminal
import XCTest

final class MobileSFTPRealOpenSSHTests: XCTestCase {
	func testUploadDownloadProgressAndIntegrityAgainstRealOpenSSH() async throws {
		let fixture = try Self.fixture()
		let client = try await MobileSFTPClient.connect(
			host: fixture.host(credential: .password),
			plan: SSHAuthPlan(attempts: [.password(fixture.password)], missing: nil),
			knownHosts: MobileKnownHostsStore(fileURL: fixture.knownHostsURL())
		)
		defer { client.close() }
		let remotePath = "\(fixture.directory)/transfer-\(UUID().uuidString.lowercased()).bin"
		let workspace = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-sftp-transfer-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: workspace) }
		let source = workspace.appendingPathComponent("source.bin")
		let destination = workspace.appendingPathComponent("destination.bin")
		let bytes = Data((0..<(512 * 1_024)).map { UInt8($0 % 251) })
		try bytes.write(to: source)
		let uploaded = ProgressRecorder()
		let downloaded = ProgressRecorder()

		do {
			let uploadResult = try await client.upload(
				localURL: source,
				remotePath: remotePath,
				progress: { await uploaded.append($0) }
			)
			let downloadResult = try await client.download(
				remotePath: remotePath,
				localURL: destination,
				progress: { await downloaded.append($0) }
			)

			XCTAssertEqual(uploadResult, Int64(bytes.count))
			XCTAssertEqual(downloadResult, Int64(bytes.count))
			XCTAssertEqual(try Data(contentsOf: destination), bytes)
			await assertMonotonic(await uploaded.values(), total: Int64(bytes.count))
			await assertMonotonic(await downloaded.values(), total: Int64(bytes.count))
			try await client.delete(at: remotePath, isDirectory: false)
		} catch {
			try? await client.delete(at: remotePath, isDirectory: false)
			throw error
		}
	}

	func testCancellationClosesTransportAndFreshRetryCompletes() async throws {
		let fixture = try Self.fixture()
		let knownHostsURL = fixture.knownHostsURL()
		let client = try await MobileSFTPClient.connect(
			host: fixture.host(credential: .password),
			plan: SSHAuthPlan(attempts: [.password(fixture.password)], missing: nil),
			knownHosts: MobileKnownHostsStore(fileURL: knownHostsURL)
		)
		defer { client.close() }
		let remotePath = "\(fixture.directory)/cancel-\(UUID().uuidString.lowercased()).bin"
		let workspace = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-sftp-cancel-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: workspace) }
		let source = workspace.appendingPathComponent("source.bin")
		let destination = workspace.appendingPathComponent("destination.bin")
		let bytes = Data(repeating: 0x5a, count: 8 * 1_024 * 1_024)
		try bytes.write(to: source)
		let gate = TransferCancellationGate()
		let cancelled = Task {
			try await client.upload(
				localURL: source,
				remotePath: remotePath,
				progress: { update in
					guard update.bytesTransferred > 0 else { return }
					await gate.markStarted()
					try? await Task.sleep(for: .milliseconds(100))
				}
			)
		}
		await gate.waitUntilStarted()
		cancelled.cancel()
		do {
			_ = try await cancelled.value
			XCTFail("Expected cancellation")
		} catch let error as MobileSFTPError {
			XCTAssertEqual(error, .cancelled)
		}

		let retry = try await MobileSFTPClient.connect(
			host: fixture.host(credential: .password),
			plan: SSHAuthPlan(attempts: [.password(fixture.password)], missing: nil),
			knownHosts: MobileKnownHostsStore(fileURL: knownHostsURL)
		)
		defer { retry.close() }
		do {
			do {
				_ = try await retry.stat(at: remotePath)
				XCTFail("Cancelled upload must not publish its destination")
			} catch MobileSFTPError.notFound {
				// Expected: the hidden temporary file was removed before cancellation returned.
			}
			_ = try await retry.upload(
				localURL: source,
				remotePath: remotePath,
				progress: { _ in }
			)
			_ = try await retry.download(
				remotePath: remotePath,
				localURL: destination,
				progress: { _ in }
			)
			XCTAssertEqual(try Data(contentsOf: destination), bytes)
			try await retry.delete(at: remotePath, isDirectory: false)
		} catch {
			try? await retry.delete(at: remotePath, isDirectory: false)
			throw error
		}
	}

	func testCancellationWhileWriteIsBlockedCleansTemporaryUpload() async throws {
		let fixture = try Self.fixture()
		let blocker = SFTPWriteBlocker()
		let client = try await MobileSFTPClient.connect(
			host: fixture.host(credential: .password),
			plan: SSHAuthPlan(attempts: [.password(fixture.password)], missing: nil),
			knownHosts: MobileKnownHostsStore(fileURL: fixture.knownHostsURL()),
			transferHooks: MobileSFTPTransferHooks(
				beforeWrite: { await blocker.block() },
				beforeRead: {}
			)
		)
		defer { client.close() }
		let fileName = "blocked-\(UUID().uuidString.lowercased()).bin"
		let remotePath = "\(fixture.directory)/\(fileName)"
		let source = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-sftp-blocked-\(UUID().uuidString)")
		try Data(repeating: 0x3c, count: 128 * 1_024).write(to: source)
		defer { try? FileManager.default.removeItem(at: source) }
		let upload = Task {
			try await client.upload(
				localURL: source,
				remotePath: remotePath,
				progress: { _ in }
			)
		}

		await blocker.waitUntilBlocked()
		upload.cancel()
		await blocker.release()

		do {
			_ = try await upload.value
			XCTFail("Expected cancellation")
		} catch let error as MobileSFTPError {
			XCTAssertEqual(error, .cancelled)
		}

		let inspection = try await MobileSFTPClient.connect(
			host: fixture.host(credential: .password),
			plan: SSHAuthPlan(attempts: [.password(fixture.password)], missing: nil),
			knownHosts: MobileKnownHostsStore(fileURL: fixture.knownHostsURL())
		)
		defer { inspection.close() }
		let entries = try await inspection.listDirectory(at: fixture.directory)
		XCTAssertFalse(entries.contains { entry in
			entry.name.hasPrefix(".\(fileName).caterm-upload-")
		})
	}

	func testCancellationWhileReadIsBlockedReturnsCancelled() async throws {
		let fixture = try Self.fixture()
		let remotePath = "\(fixture.directory)/blocked-read-\(UUID().uuidString.lowercased()).bin"
		let workspace = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-sftp-read-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: workspace) }
		let source = workspace.appendingPathComponent("source.bin")
		let destination = workspace.appendingPathComponent("destination.bin")
		try Data(repeating: 0x2a, count: 128 * 1_024).write(to: source)

		let setup = try await MobileSFTPClient.connect(
			host: fixture.host(credential: .password),
			plan: SSHAuthPlan(attempts: [.password(fixture.password)], missing: nil),
			knownHosts: MobileKnownHostsStore(fileURL: fixture.knownHostsURL())
		)
		_ = try await setup.upload(
			localURL: source,
			remotePath: remotePath,
			progress: { _ in }
		)
		setup.close()

		let blocker = SFTPReadBlocker()
		let client = try await MobileSFTPClient.connect(
			host: fixture.host(credential: .password),
			plan: SSHAuthPlan(attempts: [.password(fixture.password)], missing: nil),
			knownHosts: MobileKnownHostsStore(fileURL: fixture.knownHostsURL()),
			transferHooks: MobileSFTPTransferHooks(
				beforeWrite: {},
				beforeRead: { await blocker.block() }
			)
		)
		defer { client.close() }
		let download = Task {
			try await client.download(
				remotePath: remotePath,
				localURL: destination,
				progress: { _ in }
			)
		}

		await blocker.waitUntilBlocked()
		download.cancel()
		await blocker.release()
		do {
			_ = try await download.value
			XCTFail("Expected cancellation")
		} catch let error as MobileSFTPError {
			XCTAssertEqual(error, .cancelled)
		}

		let cleanup = try await MobileSFTPClient.connect(
			host: fixture.host(credential: .password),
			plan: SSHAuthPlan(attempts: [.password(fixture.password)], missing: nil),
			knownHosts: MobileKnownHostsStore(fileURL: fixture.knownHostsURL())
		)
		defer { cleanup.close() }
		try await cleanup.delete(at: remotePath, isDirectory: false)
	}

	func testUploadConflictPreservesDestinationAndReplaceCommitsCompleteFile() async throws {
		let fixture = try Self.fixture()
		let client = try await MobileSFTPClient.connect(
			host: fixture.host(credential: .password),
			plan: SSHAuthPlan(attempts: [.password(fixture.password)], missing: nil),
			knownHosts: MobileKnownHostsStore(fileURL: fixture.knownHostsURL())
		)
		defer { client.close() }
		let remoteName = "conflict-\(UUID().uuidString.lowercased()).bin"
		let remotePath = "\(fixture.directory)/\(remoteName)"
		let workspace = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-sftp-conflict-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: workspace) }
		let originalSource = workspace.appendingPathComponent("original.bin")
		let replacementSource = workspace.appendingPathComponent("replacement.bin")
		let destination = workspace.appendingPathComponent("destination.bin")
		let original = Data(repeating: 0x31, count: 96 * 1_024)
		let replacement = Data(repeating: 0x52, count: 160 * 1_024)
		try original.write(to: originalSource)
		try replacement.write(to: replacementSource)

		do {
			_ = try await client.upload(
				localURL: originalSource,
				remotePath: remotePath,
				progress: { _ in }
			)
			await assertThrows(.alreadyExists(path: remotePath)) {
				_ = try await client.upload(
					localURL: replacementSource,
					remotePath: remotePath,
					progress: { _ in }
				)
			}
			_ = try await client.download(
				remotePath: remotePath,
				localURL: destination,
				progress: { _ in }
			)
			XCTAssertEqual(try Data(contentsOf: destination), original)
			let namesAfterConflict = try await client.listDirectory(at: fixture.directory)
				.map(\.name)
			XCTAssertFalse(namesAfterConflict.contains {
				$0.hasPrefix(".\(remoteName).caterm-upload-")
			})

			_ = try await client.upload(
				localURL: replacementSource,
				remotePath: remotePath,
				replaceExisting: true,
				progress: { _ in }
			)
			try FileManager.default.removeItem(at: destination)
			_ = try await client.download(
				remotePath: remotePath,
				localURL: destination,
				progress: { _ in }
			)
			XCTAssertEqual(try Data(contentsOf: destination), replacement)
			try await client.delete(at: remotePath, isDirectory: false)
		} catch {
			try? await client.delete(at: remotePath, isDirectory: false)
			throw error
		}
	}

	func testPasswordAndManagedKeyListRealOpenSSHDirectory() async throws {
		let fixture = try Self.fixture()
		for (credential, plan) in [
			(CredentialSource.password, SSHAuthPlan(
				attempts: [.password(fixture.password)], missing: nil
			)),
			(.keyFile(keyPath: "managed", hasPassphrase: false), SSHAuthPlan(
				attempts: [.privateKey(
					blob: OpenSSHPrivateKeyParserTests.privateKey,
					passphrase: nil
				)], missing: nil
			)),
		] {
			let client = try await MobileSFTPClient.connect(
				host: fixture.host(credential: credential),
				plan: plan,
				knownHosts: MobileKnownHostsStore(fileURL: fixture.knownHostsURL())
			)
			defer { client.close() }

			let entries = try await client.listDirectory(at: fixture.directory)

			let folder = try XCTUnwrap(entries.first { $0.name == "folder" })
			let file = try XCTUnwrap(entries.first { $0.name == "hello.txt" })
			XCTAssertTrue(folder.isDirectory)
			XCTAssertFalse(file.isDirectory)
			XCTAssertEqual(file.size, 12)
			XCTAssertNotNil(file.modificationDate)
			XCTAssertEqual(file.permissions, 0o644)
			XCTAssertEqual(file.path, "\(fixture.directory)/hello.txt")
		}
	}

	func testChangedHostKeyFailsBeforeOpeningSFTP() async throws {
		let fixture = try Self.fixture()
		let knownHostsURL = fixture.knownHostsURL()
		try MobileKnownHostsStore(fileURL: knownHostsURL).trust(
			endpoint: "\(fixture.hostname):\(fixture.port)",
			fingerprint: "SHA256:not-the-server"
		)

		do {
			_ = try await MobileSFTPClient.connect(
				host: fixture.host(credential: .password),
				plan: SSHAuthPlan(
					attempts: [.password(fixture.password)], missing: nil
				),
				knownHosts: MobileKnownHostsStore(fileURL: knownHostsURL)
			)
			XCTFail("Expected changed host key failure")
		} catch let error as MobileSSHTrustError {
			XCTAssertEqual(
				error,
				.changed(endpoint: "\(fixture.hostname):\(fixture.port)")
			)
		}
	}

	func testLogicalHomePathUsesSFTPWorkingDirectory() async throws {
		let fixture = try Self.fixture()
		let client = try await MobileSFTPClient.connect(
			host: fixture.host(credential: .password),
			plan: SSHAuthPlan(
				attempts: [.password(fixture.password)], missing: nil
			),
			knownHosts: MobileKnownHostsStore(fileURL: fixture.knownHostsURL())
		)
		defer { client.close() }

		let entries = try await client.listDirectory(at: "~")
		let fixtureEntries = try await client.listDirectory(at: "~/sftp-fixture")

		XCTAssertFalse(entries.isEmpty)
		XCTAssertTrue(entries.allSatisfy { $0.path.hasPrefix("/") })
		XCTAssertEqual(Set(fixtureEntries.map(\.name)), ["empty", "folder", "hello.txt"])
	}

	func testCreateRenameDeleteAndTypedFailuresAgainstRealOpenSSH() async throws {
		let fixture = try Self.fixture()
		let client = try await MobileSFTPClient.connect(
			host: fixture.host(credential: .password),
			plan: SSHAuthPlan(attempts: [.password(fixture.password)], missing: nil),
			knownHosts: MobileKnownHostsStore(fileURL: fixture.knownHostsURL())
		)
		defer { client.close() }
		let root = "\(fixture.directory)/mutation-\(UUID().uuidString.lowercased())"
		let source = "\(root)/source"
		let nested = "\(source)/nested"
		let renamed = "\(root)/renamed"
		let conflict = "\(root)/conflict"

		try await client.createDirectory(at: root)
		do {
			try await client.createDirectory(at: source)
			try await client.createDirectory(at: nested)
			await assertThrows(.directoryNotEmpty(path: source)) {
				try await client.delete(at: source, isDirectory: true)
			}
			try await client.delete(at: nested, isDirectory: true)
			try await client.createDirectory(at: conflict)
			await assertThrows(.alreadyExists(path: conflict)) {
				try await client.createDirectory(at: conflict)
			}
			await assertThrows(.alreadyExists(path: conflict)) {
				try await client.rename(from: source, to: conflict)
			}
			try await client.rename(from: source, to: renamed)
			let names = Set(try await client.listDirectory(at: root).map(\.name))
			XCTAssertEqual(names, ["conflict", "renamed"])
			try await client.delete(at: renamed, isDirectory: true)
			try await client.delete(at: conflict, isDirectory: true)
			try await client.delete(at: root, isDirectory: true)
		} catch {
			try? await client.delete(at: nested, isDirectory: true)
			try? await client.delete(at: source, isDirectory: true)
			try? await client.delete(at: renamed, isDirectory: true)
			try? await client.delete(at: conflict, isDirectory: true)
			try? await client.delete(at: root, isDirectory: true)
			throw error
		}
	}

	func testDanglingSymbolicLinkIsReportedAsConflict() async throws {
		let fixture = try Self.fixture()
		guard let danglingLink = ProcessInfo.processInfo.environment[
			"CATERM_SFTP_DANGLING_LINK"
		] else {
			throw XCTSkip("CATERM_SFTP_DANGLING_LINK is required for this fixture case.")
		}
		let client = try await MobileSFTPClient.connect(
			host: fixture.host(credential: .password),
			plan: SSHAuthPlan(attempts: [.password(fixture.password)], missing: nil),
			knownHosts: MobileKnownHostsStore(fileURL: fixture.knownHostsURL())
		)
		defer { client.close() }

		await assertThrows(.alreadyExists(path: danglingLink)) {
			try await client.createDirectory(at: danglingLink)
		}
	}

	private func assertThrows(
		_ expected: MobileSFTPError,
		operation: () async throws -> Void
	) async {
		do {
			try await operation()
			XCTFail("Expected \(expected)")
		} catch let error as MobileSFTPError {
			XCTAssertEqual(error, expected)
		} catch {
			XCTFail("Expected \(expected), got \(error)")
		}
	}

	private func assertMonotonic(
		_ updates: [MobileSFTPTransferProgress],
		total: Int64
	) async {
		XCTAssertFalse(updates.isEmpty)
		XCTAssertEqual(updates.last?.bytesTransferred, total)
		XCTAssertTrue(updates.allSatisfy { $0.totalBytes == total })
		XCTAssertEqual(
			updates.map(\.bytesTransferred),
			updates.map(\.bytesTransferred).sorted()
		)
	}

	private struct Fixture {
		let hostname: String
		let port: Int
		let username: String
		let password: String
		let directory: String

		func host(credential: CredentialSource) -> SSHHost {
			SSHHost(
				name: "SFTP Fixture",
				hostname: hostname,
				port: port,
				username: username,
				credential: credential
			)
		}

		func knownHostsURL() -> URL {
			FileManager.default.temporaryDirectory
				.appendingPathComponent("caterm-sftp-\(UUID().uuidString).json")
		}
	}

	private static func fixture() throws -> Fixture {
		let environment = ProcessInfo.processInfo.environment
		guard environment["CATERM_SFTP_E2E"] == "1" else {
			throw XCTSkip("Set CATERM_SFTP_E2E=1 to run the real OpenSSH fixture.")
		}
		guard let port = environment["CATERM_SFTP_PORT"].flatMap(Int.init) else {
			throw XCTSkip("CATERM_SFTP_PORT is required for the real OpenSSH fixture.")
		}
		return Fixture(
			hostname: environment["CATERM_SFTP_HOST"] ?? "127.0.0.1",
			port: port,
			username: environment["CATERM_SFTP_USER"] ?? "caterm",
			password: environment["CATERM_SFTP_PASSWORD"] ?? "caterm-e2e",
			directory: environment["CATERM_SFTP_DIRECTORY"] ?? "/config/sftp-fixture"
		)
	}
}

private actor ProgressRecorder {
	private var updates: [MobileSFTPTransferProgress] = []

	func append(_ progress: MobileSFTPTransferProgress) {
		updates.append(progress)
	}

	func values() -> [MobileSFTPTransferProgress] {
		updates
	}
}

private actor TransferCancellationGate {
	private var started = false

	func markStarted() {
		started = true
	}

	func waitUntilStarted() async {
		while !started { await Task.yield() }
	}
}

private actor SFTPWriteBlocker {
	private var blocked = false
	private var continuation: CheckedContinuation<Void, Never>?

	func block() async {
		blocked = true
		await withCheckedContinuation { continuation = $0 }
	}

	func waitUntilBlocked() async {
		while !blocked { await Task.yield() }
	}

	func release() {
		continuation?.resume()
		continuation = nil
	}
}

private actor SFTPReadBlocker {
	private var blocked = false
	private var continuation: CheckedContinuation<Void, Never>?

	func block() async {
		blocked = true
		await withCheckedContinuation { continuation = $0 }
	}

	func waitUntilBlocked() async {
		while !blocked { await Task.yield() }
	}

	func release() {
		continuation?.resume()
		continuation = nil
	}
}
