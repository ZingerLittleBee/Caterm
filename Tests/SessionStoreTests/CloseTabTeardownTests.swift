import XCTest
@testable import KeychainStore
@testable import SessionStore
@testable import SSHCommandBuilder

/// Verifies the differentiated `closeTab` teardown policy:
/// - Hosts with port forwards skip the ControlMaster grace and tear down
///   immediately when the last tab closes, so listening sockets die with
///   the user-visible session.
/// - Hosts without forwards keep the existing grace-window behavior, so a
///   quick reconnect can reuse the warm master.
@MainActor
final class CloseTabTeardownTests: XCTestCase {

	private final class RecordingTearDowner: ControlMasterManaging, @unchecked Sendable {
		var tornDown: [UUID] = []
		var tearDownAllCount = 0

		@MainActor
		func socketPath(for hostId: UUID) -> URL {
			URL(fileURLWithPath: "/tmp/\(hostId.uuidString).sock")
		}

		@MainActor
		func register(hostId: UUID, destination: String) {}

		func tearDown(hostId: UUID) async {
			tornDown.append(hostId)
		}

		func tearDownAll() async {
			tearDownAllCount += 1
		}
	}

	private func makeStore(rec: RecordingTearDowner,
	                       grace: Double) -> SessionStore {
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-closetab-\(UUID()).json")
		let kc = KeychainStore(service: "com.caterm.test.\(UUID())",
		                       accessGroup: nil)
		let store = SessionStore(askpassPath: "/dev/null",
		                         knownHostsCaterm: "/dev/null",
		                         knownHostsUser: "/dev/null",
		                         accessGroup: nil,
		                         hostsURL: tmp,
		                         keychain: kc,
		                         controlMasterManager: rec)
		store.teardownGraceSeconds = grace
		return store
	}

	private func makeHost(forwards: [PortForward]) -> SSHHost {
		SSHHost(name: "h", hostname: "127.0.0.1", port: 22,
		        username: "u", credential: .password,
		        forwards: forwards)
	}

	func test_closeLastTab_hostWithForwards_tearsDownImmediately() async {
		let rec = RecordingTearDowner()
		// 999s grace would make a scheduled teardown impossible to observe
		// during the test. If a teardown is observed, it must have skipped
		// the grace.
		let store = makeStore(rec: rec, grace: 999)
		let host = makeHost(forwards: [
			PortForward(kind: .local, bindPort: 5432,
			            remoteHost: "db", remotePort: 5432),
		])
		let tabId = store.openTab(host: host)
		store.closeTab(tabId: tabId)
		// Give the immediate-teardown Task one main-actor turn to land.
		try? await Task.sleep(nanoseconds: 100_000_000)
		XCTAssertEqual(rec.tornDown, [host.id],
		               "host with forwards must tear down immediately, " +
		               "bypassing the \(store.teardownGraceSeconds)s grace")
	}

	func test_closeLastTab_hostWithoutForwards_usesGrace() async {
		let rec = RecordingTearDowner()
		let store = makeStore(rec: rec, grace: 0.05)
		let host = makeHost(forwards: [])
		let tabId = store.openTab(host: host)
		store.closeTab(tabId: tabId)
		// Before the grace elapses, nothing should have torn down.
		XCTAssertEqual(rec.tornDown, [],
		               "grace path must defer teardown")
		try? await Task.sleep(nanoseconds: 200_000_000)
		XCTAssertEqual(rec.tornDown, [host.id],
		               "after grace, the master must tear down")
	}

	func test_closeOneOfMultipleTabs_sameHost_doesNotTeardown() async {
		let rec = RecordingTearDowner()
		let store = makeStore(rec: rec, grace: 0.05)
		let host = makeHost(forwards: [
			PortForward(kind: .local, bindPort: 5432,
			            remoteHost: "db", remotePort: 5432),
		])
		let tab1 = store.openTab(host: host)
		let tab2 = store.openTab(host: host)
		store.closeTab(tabId: tab1)
		try? await Task.sleep(nanoseconds: 200_000_000)
		XCTAssertEqual(rec.tornDown, [],
		               "closing a non-last tab must not teardown even with forwards")
		store.closeTab(tabId: tab2)
		// Last tab + forwards → immediate teardown (no grace wait needed,
		// but allow one turn for the Task).
		try? await Task.sleep(nanoseconds: 200_000_000)
		XCTAssertEqual(rec.tornDown, [host.id],
		               "last tab closing should teardown the master")
	}

	func test_repeatedClose_tearsDownExactlyOnce() async {
		let rec = RecordingTearDowner()
		let store = makeStore(rec: rec, grace: 0.02)
		let host = makeHost(forwards: [])
		let tab = store.openTab(host: host)

		store.closeTab(tabId: tab)
		store.closeTab(tabId: tab)
		try? await Task.sleep(nanoseconds: 100_000_000)

		XCTAssertEqual(rec.tornDown, [host.id])
	}

	func test_closeDuringScheduledReconnect_cancelsRestartAndTearsDownOnce() async {
		let rec = RecordingTearDowner()
		let store = makeStore(rec: rec, grace: 999)
		let host = makeHost(forwards: [
			PortForward(kind: .local, bindPort: 5432,
			            remoteHost: "db", remotePort: 5432),
		])
		let tab = store.openTab(host: host)
		store.markConnected(tabId: tab)
		store.markChildExited(tabId: tab, exitCode: 255)

		store.closeTab(tabId: tab)
		store.closeTab(tabId: tab)
		try? await Task.sleep(nanoseconds: 1_200_000_000)

		XCTAssertFalse(store.tabs.contains(where: { $0.id == tab }))
		XCTAssertEqual(rec.tornDown, [host.id])
	}
}
