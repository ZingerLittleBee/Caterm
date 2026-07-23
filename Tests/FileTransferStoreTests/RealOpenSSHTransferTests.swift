#if os(macOS)
import Foundation
import XCTest
@testable import FileTransferStore
import SFTPCommandBuilder
import SSHCommandBuilder

final class RealOpenSSHTransferTests: XCTestCase {
	func testUploadAndDownloadThroughExistingControlMaster() async throws {
		let environment = ProcessInfo.processInfo.environment
		guard let controlPath = environment["CATERM_REAL_SFTP_CONTROL_PATH"],
		      !controlPath.isEmpty else {
			throw XCTSkip(
				"Requires CATERM_REAL_SFTP_CONTROL_PATH from a signed Caterm session"
			)
		}
		let port = Int(environment["CATERM_REAL_SFTP_PORT"] ?? "2223") ?? 2223
		let host = SSHHost(
			name: "real-sftp-fixture",
			hostname: environment["CATERM_REAL_SFTP_HOST"] ?? "127.0.0.1",
			port: port,
			username: environment["CATERM_REAL_SFTP_USER"] ?? "caterm",
			credential: .password
		)
		let home = FileManager.default.homeDirectoryForCurrentUser
		let client = RemoteFileSystem(
			host: host,
			controlPath: URL(fileURLWithPath: controlPath),
			credentials: SFTPCredentials(
				knownHostsCaterm: home.appendingPathComponent(
					"Library/Application Support/Caterm/known_hosts"
				),
				knownHostsUser: home.appendingPathComponent(".ssh/known_hosts"),
				strictHostKeyChecking: .acceptNew
			),
			liveness: RealFixtureLiveness()
		)
		let fixtureName = "caterm-sftp-contract-\(UUID().uuidString).txt"
		let remotePath = "~/\(fixtureName)"
		let workspace = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-real-sftp-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: workspace,
			withIntermediateDirectories: true
		)
		defer { try? FileManager.default.removeItem(at: workspace) }
		let uploadURL = workspace.appendingPathComponent("upload.txt")
		let downloadURL = workspace.appendingPathComponent("download.txt")
		let payload = Data("Caterm real OpenSSH transfer contract\n".utf8)
		try payload.write(to: uploadURL)

		do {
			let upload = try await client.upload(
				localURL: uploadURL,
				remotePath: remotePath,
				isDirectory: false,
				resume: false,
				replaceExisting: false,
				progress: { _ in }
			)
			XCTAssertEqual(upload.bytesTransferred, Int64(payload.count))
			let uploadedMetadata = try await client.stat(remotePath)
			XCTAssertEqual(uploadedMetadata?.size, Int64(payload.count))

			let download = try await client.download(
				remotePath: remotePath,
				localURL: downloadURL,
				isDirectory: false,
				resume: false,
				progress: { _ in }
			)
			XCTAssertEqual(download.bytesTransferred, Int64(payload.count))
			XCTAssertEqual(try Data(contentsOf: downloadURL), payload)
			try await client.delete(remotePath, isDirectory: false)
			let deletedMetadata = try await client.stat(remotePath)
			XCTAssertNil(deletedMetadata)
		} catch {
			try? await client.delete(remotePath, isDirectory: false)
			throw error
		}
	}

	func testRemoteCopyRelaysBetweenTwoRealOpenSSHHosts() async throws {
		let environment = ProcessInfo.processInfo.environment
		guard let firstControlPath =
				environment["CATERM_REAL_SFTP_CONTROL_PATH"],
			let secondControlPath =
				environment["CATERM_REAL_SFTP_CONTROL_PATH_2"],
			!firstControlPath.isEmpty,
			!secondControlPath.isEmpty else {
			throw XCTSkip(
				"Requires two existing ControlMaster sockets"
			)
		}
		let firstPort = Int(
			environment["CATERM_REAL_SFTP_PORT"] ?? "2223"
		) ?? 2223
		let secondPort = Int(
			environment["CATERM_REAL_SFTP_PORT_2"] ?? "2224"
		) ?? 2224
		let firstHost = makeHost(
			name: "real-sftp-source",
			port: firstPort
		)
		let secondHost = makeHost(
			name: "real-sftp-destination",
			port: secondPort
		)
		let firstClient = makeClient(
			host: firstHost,
			controlPath: firstControlPath
		)
		let secondClient = makeClient(
			host: secondHost,
			controlPath: secondControlPath
		)
		let fixtureName = "caterm-real-relay-\(UUID().uuidString).txt"
		let sourcePath = "~/\(fixtureName)"
		let destinationPath = "~/\(fixtureName)"
		let workspace = FileManager.default.temporaryDirectory
			.appendingPathComponent(
				"caterm-real-relay-\(UUID().uuidString)",
				isDirectory: true
			)
		try FileManager.default.createDirectory(
			at: workspace,
			withIntermediateDirectories: true
		)
		defer { try? FileManager.default.removeItem(at: workspace) }
		let sourceURL = workspace.appendingPathComponent("source.txt")
		let downloadedURL = workspace.appendingPathComponent("downloaded.txt")
		let payload = Data("Caterm remote relay contract\n".utf8)
		try payload.write(to: sourceURL)
		_ = try await firstClient.upload(
			localURL: sourceURL,
			remotePath: sourcePath,
			isDirectory: false,
			resume: false,
			replaceExisting: false,
			progress: { _ in }
		)
		defer {
			Task {
				try? await firstClient.delete(
					sourcePath,
					isDirectory: false
				)
				try? await secondClient.delete(
					destinationPath,
					isDirectory: false
				)
			}
		}
		let store = await MainActor.run {
			FileTransferStore { host in
				host.id == firstHost.id ? firstClient : secondClient
			}
		}

		let taskID = try await MainActor.run {
			try XCTUnwrap(
				store.enqueueRemoteCopy(
					remotePaths: [sourcePath],
					destinationDirectory: "~",
					sourceHost: firstHost,
					destinationHost: secondHost
				).first
			)
		}
		try await store.waitIdle()
		let status = await MainActor.run { store.task(id: taskID)?.status }
		XCTAssertEqual(status, .completed)
		_ = try await secondClient.download(
			remotePath: destinationPath,
			localURL: downloadedURL,
			isDirectory: false,
			resume: false,
			progress: { _ in }
		)
		XCTAssertEqual(try Data(contentsOf: downloadedURL), payload)
		try await firstClient.delete(sourcePath, isDirectory: false)
		try await secondClient.delete(destinationPath, isDirectory: false)
	}

	private func makeHost(name: String, port: Int) -> SSHHost {
		let environment = ProcessInfo.processInfo.environment
		return SSHHost(
			name: name,
			hostname: environment["CATERM_REAL_SFTP_HOST"] ?? "127.0.0.1",
			port: port,
			username: environment["CATERM_REAL_SFTP_USER"] ?? "caterm",
			credential: .password
		)
	}

	private func makeClient(
		host: SSHHost,
		controlPath: String
	) -> RemoteFileSystem {
		let home = FileManager.default.homeDirectoryForCurrentUser
		return RemoteFileSystem(
			host: host,
			controlPath: URL(fileURLWithPath: controlPath),
			credentials: SFTPCredentials(
				knownHostsCaterm: home.appendingPathComponent(
					"Library/Application Support/Caterm/known_hosts"
				),
				knownHostsUser: home.appendingPathComponent(
					".ssh/known_hosts"
				),
				strictHostKeyChecking: .acceptNew
			),
			liveness: RealFixtureLiveness()
		)
	}
}

private struct RealFixtureLiveness: ControlMasterLiveness {
	func isAlive(hostId: UUID) async -> Bool { true }
}
#endif
