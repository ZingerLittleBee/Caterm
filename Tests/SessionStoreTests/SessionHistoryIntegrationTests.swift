import KeychainStore
import SessionHistory
import SSHCommandBuilder
import XCTest
@testable import SessionStore

@MainActor
final class SessionHistoryIntegrationTests: XCTestCase {
	func testOneTimeConnectionRecordsCompletedLifecycle() throws {
		let history = SessionHistoryStore(fileURL: temporaryURL("history.json"))
		let store = makeStore(historyRecorder: history)
		let host = SSHHost(
			name: "One-time",
			hostname: "example.com",
			username: "alice",
			credential: .agent
		)

		let tabID = store.openTab(
			host: host,
			authenticationMode: .interactive
		)

		XCTAssertEqual(history.entries.first?.connectionKind, .oneTime)
		XCTAssertNil(history.entries.first?.host.savedHostID)
		XCTAssertEqual(history.entries.first?.state, .connecting)

		store.markConnected(tabId: tabID)
		guard case .connected = history.entries.first?.state else {
			return XCTFail("Expected connected history state")
		}
		store.closeTab(tabId: tabID)
		guard case .ended(_, _, let outcome) = history.entries.first?.state else {
			return XCTFail("Expected ended history state")
		}
		XCTAssertEqual(outcome, .completed)
	}

	func testBrokenSavedHostChainRecordsFailure() throws {
		let history = SessionHistoryStore(fileURL: temporaryURL("history.json"))
		let store = makeStore(historyRecorder: history)
		let host = SSHHost(
			name: "Production",
			hostname: "prod.example.com",
			username: "deploy",
			credential: .agent,
			jumpHostId: UUID()
		)
		try store.addHost(host)

		_ = store.openTab(host: host)

		XCTAssertEqual(history.entries.first?.connectionKind, .savedHost)
		XCTAssertEqual(history.entries.first?.host.savedHostID, host.id)
		guard case .ended(_, _, let outcome) = history.entries.first?.state else {
			return XCTFail("Expected ended history state")
		}
		XCTAssertEqual(outcome, .failed)
	}

	func testRetryStartsANewHistoryEntry() {
		let history = SessionHistoryStore(fileURL: temporaryURL("history.json"))
		let store = makeStore(historyRecorder: history)
		let tabID = store.openTab(
			host: SSHHost(
				name: "Retry",
				hostname: "example.com",
				username: "alice",
				credential: .agent
			),
			authenticationMode: .interactive
		)
		store.markChildExited(tabId: tabID, exitCode: 255)

		store.retryTab(tabId: tabID)

		XCTAssertEqual(history.entries.count, 2)
		XCTAssertEqual(history.entries.first?.state, .connecting)
		guard case .ended(_, _, let previousOutcome) = history.entries.last?.state else {
			return XCTFail("Expected the previous attempt to be ended")
		}
		XCTAssertEqual(previousOutcome, .failed)
		store.closeTab(tabId: tabID)
		guard case .ended(_, _, let retryOutcome) = history.entries.first?.state else {
			return XCTFail("Expected the retry to be ended")
		}
		XCTAssertEqual(retryOutcome, .cancelled)
	}

	private func makeStore(
		historyRecorder: SessionHistoryRecording
	) -> SessionStore {
		SessionStore(
			askpassPath: "/dev/null",
			knownHostsCaterm: "/dev/null",
			knownHostsUser: "/dev/null",
			accessGroup: nil,
			hostsURL: temporaryURL("hosts.json"),
			keychain: KeychainStore(
				service: "test.session-history.\(UUID())",
				accessGroup: nil
			),
			historyRecorder: historyRecorder
		)
	}

	private func temporaryURL(_ filename: String) -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-session-store-history-\(UUID())")
		addTeardownBlock {
			try? FileManager.default.removeItem(at: directory)
		}
		return directory.appendingPathComponent(filename)
	}
}
