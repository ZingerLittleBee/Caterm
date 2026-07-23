import Foundation
import Testing
@testable import Caterm
@testable import FileTransferStore

@Suite("SFTP task window model")
@MainActor
struct SFTPTaskWindowModelTests {
	private struct BookmarkCodec: SecurityScopedBookmarkCoding {
		let requiresSecurityScope = false

		func createBookmark(for url: URL) throws -> Data {
			Data(url.path.utf8)
		}

		func resolveBookmark(
			_ data: Data
		) throws -> SecurityScopedBookmarkResolution {
			SecurityScopedBookmarkResolution(
				url: URL(
					fileURLWithPath:
						String(decoding: data, as: UTF8.self),
					isDirectory: true
				),
				isStale: false
			)
		}

		func startAccessing(_: URL) -> Bool { true }
		func stopAccessing(_: URL) {}
		func isReachable(_: URL) -> Bool { true }
	}

	@Test("Choosing a folder adds it while recovery replaces only the requested location")
	func localAuthorizationIntentIsExplicit() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent(
				"caterm-sftp-model-\(UUID().uuidString)",
				isDirectory: true
			)
		let first = root.appendingPathComponent("First", isDirectory: true)
		let second = root.appendingPathComponent("Second", isDirectory: true)
		let restored = root.appendingPathComponent("Restored", isDirectory: true)
		try FileManager.default.createDirectory(
			at: first,
			withIntermediateDirectories: true
		)
		try FileManager.default.createDirectory(
			at: second,
			withIntermediateDirectories: true
		)
		try FileManager.default.createDirectory(
			at: restored,
			withIntermediateDirectories: true
		)
		defer { try? FileManager.default.removeItem(at: root) }

		let locationStore = LocalFileLocationStore(
			fileURL: root.appendingPathComponent("locations.json"),
			bookmarkCodec: BookmarkCodec()
		)
		let model = SFTPTaskWindowModel(locationStore: locationStore)
		let transferStore = FileTransferStore { _ in
			fatalError("A local refresh must not create a remote client")
		}

		await model.authorizeLocal(
			url: first,
			replacing: nil,
			for: .left,
			hosts: [],
			transferStore: transferStore
		)
		let firstLocation = try #require(model.locations.first)

		await model.authorizeLocal(
			url: second,
			replacing: nil,
			for: .left,
			hosts: [],
			transferStore: transferStore
		)
		#expect(model.locations.map(\.displayName) == ["First", "Second"])

		await model.authorizeLocal(
			url: restored,
			replacing: firstLocation.id,
			for: .left,
			hosts: [],
			transferStore: transferStore
		)
		#expect(model.locations.map(\.displayName) == ["Restored", "Second"])
		#expect(
			model.state(for: .left).endpoint
				== .local(locationID: firstLocation.id)
		)
	}
}
