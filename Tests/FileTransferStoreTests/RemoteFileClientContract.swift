import Foundation
import XCTest
@testable import FileTransferStore

enum RemoteFileClientContract {
	static func verifyBehavior(
		client: any RemoteFileClient,
		workspace: URL
	) async throws {
		let uploadURL = workspace.appendingPathComponent("upload.txt")
		let downloadURL = workspace.appendingPathComponent("download.txt")
		try Data("data".utf8).write(to: uploadURL)
		let progress = ContractProgressRecorder()

		let entries = try await client.list("/remote")
		let metadata = try await client.stat("/remote/file.txt")
		XCTAssertEqual(entries.map(\.name), ["file.txt"])
		XCTAssertEqual(metadata?.size, 4)

		try await client.createDirectory("/remote/new")
		try await client.rename(from: "/remote/new", to: "/remote/renamed")
		try await client.delete("/remote/renamed", isDirectory: true)

		let upload = try await client.upload(
			localURL: uploadURL,
			remotePath: "/remote/file.txt",
			isDirectory: false,
			resume: false,
			replaceExisting: false,
			progress: { update in await progress.append(update) }
		)
		let download = try await client.download(
			remotePath: "/remote/file.txt",
			localURL: downloadURL,
			isDirectory: false,
			resume: false,
			progress: { update in await progress.append(update) }
		)

		XCTAssertEqual(upload.bytesTransferred, 4)
		XCTAssertEqual(download.bytesTransferred, 4)
		XCTAssertEqual(try Data(contentsOf: downloadURL), Data("data".utf8))
		let updates = await progress.values()
		XCTAssertEqual(updates.last?.bytesTransferred, 4)
	}

	static func verifyTypedCancellation(
		client: any RemoteFileClient
	) async {
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

private actor ContractProgressRecorder {
	private var updates: [TransferProgress] = []

	func append(_ update: TransferProgress) {
		updates.append(update)
	}

	func values() -> [TransferProgress] {
		updates
	}
}
