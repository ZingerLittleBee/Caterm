import FileTransferStore
import Foundation
import SSHCommandBuilder
@testable import CatermMobile
@testable import CatermMobileTerminal
import XCTest

final class MobileRemoteFileClientRealOpenSSHTests: XCTestCase {
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
