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
}

private struct RealFixtureLiveness: ControlMasterLiveness {
	func isAlive(hostId: UUID) async -> Bool { true }
}
#endif
