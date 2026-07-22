import Foundation
import SSHCommandBuilder
@testable import CatermMobileTerminal
import XCTest

final class MobileSFTPRealOpenSSHTests: XCTestCase {
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
