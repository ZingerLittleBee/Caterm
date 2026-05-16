import XCTest
@testable import SnippetSyncClient

final class SnippetTests: XCTestCase {
	func test_codable_roundTrip() throws {
		let original = Snippet(
			id: UUID(),
			name: "List docker containers",
			content: "docker ps -a",
			placeholders: nil,
			createdAt: Date(timeIntervalSince1970: 1_700_000_000),
			updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
			serverId: "abc",
			revision: 3,
			metadataUpdatedAt: Date(timeIntervalSince1970: 1_700_000_002)
		)

		let data = try JSONEncoder().encode(original)
		let decoded = try JSONDecoder().decode(Snippet.self, from: data)

		XCTAssertEqual(decoded, original)
	}

	func test_codable_nilOptionalsPreserved() throws {
		let original = Snippet(
			id: UUID(),
			name: "x",
			content: "y",
			placeholders: nil,
			createdAt: .distantPast,
			updatedAt: .distantPast,
			serverId: nil,
			revision: 0,
			metadataUpdatedAt: nil
		)
		let data = try JSONEncoder().encode(original)
		let decoded = try JSONDecoder().decode(Snippet.self, from: data)
		XCTAssertEqual(decoded, original)
		XCTAssertNil(decoded.placeholders)
		XCTAssertNil(decoded.serverId)
		XCTAssertNil(decoded.metadataUpdatedAt)
	}
}
