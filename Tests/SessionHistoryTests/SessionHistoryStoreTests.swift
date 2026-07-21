import XCTest
@testable import SessionHistory

@MainActor
final class SessionHistoryStoreTests: XCTestCase {
	func testBeginPersistsAConnectingSession() throws {
		let fileURL = temporaryFileURL()
		let store = SessionHistoryStore(fileURL: fileURL)
		let startedAt = Date(timeIntervalSince1970: 1_721_600_000)
		let host = SessionHistoryHost(
			savedHostID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
			displayName: "Production",
			hostname: "prod.example.com",
			port: 2202,
			username: "deploy"
		)

		let entryID = try store.begin(
			host: host,
			connectionKind: .savedHost,
			at: startedAt
		)

		XCTAssertEqual(
			store.entries,
			[
				SessionHistoryEntry(
					id: entryID,
					host: host,
					connectionKind: .savedHost,
					startedAt: startedAt,
					state: .connecting
				)
			]
		)

		let reloaded = SessionHistoryStore(fileURL: fileURL)
		try reloaded.load()
		XCTAssertEqual(reloaded.entries, store.entries)
	}

	func testConnectedSessionFinishesWithDurationMetadata() throws {
		let store = SessionHistoryStore(fileURL: temporaryFileURL())
		let startedAt = Date(timeIntervalSince1970: 1_721_600_000)
		let connectedAt = startedAt.addingTimeInterval(4)
		let endedAt = startedAt.addingTimeInterval(64)
		let entryID = try store.begin(
			host: SessionHistoryHost(
				savedHostID: nil,
				displayName: "Ad hoc",
				hostname: "example.com",
				port: 22,
				username: "alice"
			),
			connectionKind: .oneTime,
			at: startedAt
		)

		try store.markConnected(id: entryID, at: connectedAt)
		try store.finish(id: entryID, outcome: .completed, at: endedAt)

		XCTAssertEqual(
			store.entries.first?.state,
			.ended(
				connectedAt: connectedAt,
				endedAt: endedAt,
				outcome: .completed
			)
		)
		XCTAssertEqual(store.entries.first?.duration, 64)
	}

	func testLoadRecoversAnActiveSessionAsInterrupted() throws {
		let fileURL = temporaryFileURL()
		let startedAt = Date(timeIntervalSince1970: 1_721_600_000)
		let connectedAt = startedAt.addingTimeInterval(4)
		let recoveredAt = startedAt.addingTimeInterval(120)
		let original = SessionHistoryStore(fileURL: fileURL)
		let entryID = try original.begin(
			host: SessionHistoryHost(
				savedHostID: nil,
				displayName: "Interrupted",
				hostname: "example.com",
				port: 22,
				username: "alice"
			),
			connectionKind: .oneTime,
			at: startedAt
		)
		try original.markConnected(id: entryID, at: connectedAt)

		let recovered = SessionHistoryStore(fileURL: fileURL)
		try recovered.load(recoveringAt: recoveredAt)

		XCTAssertEqual(
			recovered.entries.first?.state,
			.ended(
				connectedAt: connectedAt,
				endedAt: recoveredAt,
				outcome: .interrupted
			)
		)
		let reloaded = SessionHistoryStore(fileURL: fileURL)
		try reloaded.load()
		XCTAssertEqual(reloaded.entries, recovered.entries)
	}

	func testRetentionKeepsNewestEntriesAndClearPersists() throws {
		let fileURL = temporaryFileURL()
		let store = SessionHistoryStore(fileURL: fileURL, retentionLimit: 2)
		let host = SessionHistoryHost(
			savedHostID: nil,
			displayName: "Host",
			hostname: "example.com",
			port: 22,
			username: "alice"
		)
		let firstID = try store.begin(
			host: host,
			connectionKind: .oneTime,
			at: Date(timeIntervalSince1970: 1)
		)
		let secondID = try store.begin(
			host: host,
			connectionKind: .oneTime,
			at: Date(timeIntervalSince1970: 2)
		)
		let thirdID = try store.begin(
			host: host,
			connectionKind: .oneTime,
			at: Date(timeIntervalSince1970: 3)
		)

		XCTAssertEqual(store.entries.map(\.id), [thirdID, secondID])
		XCTAssertFalse(store.entries.contains(where: { $0.id == firstID }))
		let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
		let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
		XCTAssertEqual(permissions.intValue & 0o777, 0o600)

		try store.clear()
		XCTAssertTrue(store.entries.isEmpty)
		let reloaded = SessionHistoryStore(fileURL: fileURL)
		try reloaded.load()
		XCTAssertTrue(reloaded.entries.isEmpty)
	}

	private func temporaryFileURL() -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-session-history-\(UUID())")
		addTeardownBlock {
			try? FileManager.default.removeItem(at: directory)
		}
		return directory.appendingPathComponent("session-history.json")
	}
}
