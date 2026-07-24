import FileTransferStore
import Foundation
import SSHCommandBuilder
@testable import CatermMobile
@testable import CatermMobileTerminal
import XCTest

final class MobileRemoteFileClientRealOpenSSHTests: XCTestCase {
	func testPublicClientTransfersBytesAndReportsProgress() async throws {
		let fixture = try Self.fixture()
		let knownHostsURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-public-transfer-\(UUID().uuidString).json")
		let client = makeClient(fixture: fixture, knownHostsURL: knownHostsURL)
		let remotePath = "\(fixture.directory)/public-transfer-\(UUID().uuidString.lowercased()).bin"
		let workspace = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-public-transfer-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: workspace) }
		let source = workspace.appendingPathComponent("source.bin")
		let destination = workspace.appendingPathComponent("destination.bin")
		let bytes = Data((0..<(384 * 1_024)).map { UInt8($0 % 239) })
		try bytes.write(to: source)
		let progress = PublicProgressRecorder()

		do {
			let upload = try await client.upload(
				localURL: source,
				remotePath: remotePath,
				isDirectory: false,
				resume: false,
				replaceExisting: false,
				progress: { await progress.append($0) }
			)
			await client.disconnect()
			let reconnected = makeClient(
				fixture: fixture,
				knownHostsURL: knownHostsURL
			)
			let download = try await reconnected.download(
				remotePath: remotePath,
				localURL: destination,
				isDirectory: false,
				resume: false,
				progress: { await progress.append($0) }
			)

			XCTAssertEqual(upload.bytesTransferred, Int64(bytes.count))
			XCTAssertEqual(download.bytesTransferred, Int64(bytes.count))
			XCTAssertEqual(try Data(contentsOf: destination), bytes)
			let isMonotonic = await progress.isMonotonic()
			XCTAssertTrue(isMonotonic)
			try await reconnected.delete(remotePath, isDirectory: false)
			await reconnected.disconnect()
		} catch {
			try? await client.delete(remotePath, isDirectory: false)
			await client.disconnect()
			throw error
		}
	}

	func testPublicClientMapsLocalAndRemoteTransferFailures() async throws {
		let fixture = try Self.fixture()
		let knownHostsURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-public-errors-\(UUID().uuidString).json")
		let client = makeClient(fixture: fixture, knownHostsURL: knownHostsURL)
		let workspace = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-public-errors-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: workspace) }
		_ = try await client.list(fixture.directory)

		await assertRemoteError(.localIO(message: ""), matchingCaseOnly: true) {
			_ = try await client.upload(
				localURL: workspace.appendingPathComponent("missing.bin"),
				remotePath: "\(fixture.directory)/missing.bin",
				isDirectory: false,
				resume: false,
				replaceExisting: false,
				progress: { _ in }
			)
		}
		let missingRemote = "\(fixture.directory)/missing-\(UUID().uuidString).bin"
		await assertRemoteError(.notFound(path: missingRemote)) {
			_ = try await client.download(
				remotePath: missingRemote,
				localURL: workspace.appendingPathComponent("download.bin"),
				isDirectory: false,
				resume: false,
				progress: { _ in }
			)
		}
		await client.disconnect()
	}

	func testPublicClientMutationsSurviveDisconnectAndReconnect() async throws {
		let fixture = try Self.fixture()
		let knownHostsURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-public-sftp-\(UUID().uuidString).json")
		let root = "\(fixture.directory)/public-\(UUID().uuidString.lowercased())"
		let first = makeClient(fixture: fixture, knownHostsURL: knownHostsURL)

		try await first.createDirectory(root)
		try await first.createDirectory("\(root)/draft")
		try await first.rename(from: "\(root)/draft", to: "\(root)/final")
		let statResult = try await first.stat(root)
		let rootEntry = try XCTUnwrap(statResult)
		XCTAssertTrue(rootEntry.isDirectory)
		let firstListing = try await first.list(root)
		XCTAssertEqual(firstListing.map(\.name), ["final"])
		await first.disconnect()

		let reconnected = makeClient(fixture: fixture, knownHostsURL: knownHostsURL)
		do {
			let reconnectedListing = try await reconnected.list(root)
			XCTAssertEqual(reconnectedListing.map(\.name), ["final"])
			try await reconnected.delete("\(root)/final", isDirectory: true)
			let emptyListing = try await reconnected.list(root)
			XCTAssertTrue(emptyListing.isEmpty)
			try await reconnected.delete(root, isDirectory: true)
			await reconnected.disconnect()
		} catch {
			try? await reconnected.delete("\(root)/final", isDirectory: true)
			try? await reconnected.delete(root, isDirectory: true)
			await reconnected.disconnect()
			throw error
		}
	}

	private func makeClient(
		fixture: Fixture,
		knownHostsURL: URL
	) -> MobileRemoteFileClient {
		MobileRemoteFileClient(
			host: SSHHost(
				name: "SFTP Fixture",
				hostname: fixture.hostname,
				port: fixture.port,
				username: fixture.username,
				credential: .password
			),
			plan: SSHAuthPlan(attempts: [.password(fixture.password)], missing: nil),
			knownHosts: MobileKnownHostsStore(fileURL: knownHostsURL)
		)
	}

	private func assertRemoteError(
		_ expected: RemoteFileError,
		matchingCaseOnly: Bool = false,
		operation: () async throws -> Void
	) async {
		do {
			try await operation()
			XCTFail("Expected \(expected)")
		} catch let error as RemoteFileError {
			if matchingCaseOnly,
				case .localIO = expected,
				case .localIO = error {
				return
			}
			XCTAssertEqual(error, expected)
		} catch {
			XCTFail("Expected \(expected), got \(error)")
		}
	}

	private struct Fixture {
		let hostname: String
		let port: Int
		let username: String
		let password: String
		let directory: String
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

private actor PublicProgressRecorder {
	private var updates: [TransferProgress] = []

	func append(_ update: TransferProgress) {
		updates.append(update)
	}

	func isMonotonic() -> Bool {
		let grouped = updates.split { $0.bytesTransferred == 0 }
		return grouped.allSatisfy { group in
			let values = group.map(\.bytesTransferred)
			return values == values.sorted()
		}
	}
}
