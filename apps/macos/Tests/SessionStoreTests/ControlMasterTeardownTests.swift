import XCTest
@testable import KeychainStore
@testable import SessionStore
@testable import SSHCommandBuilder

/// Records calls to `tearDown` / `tearDownAll` so tests can assert which
/// host ids were torn down (and which were not). `@unchecked Sendable` is
/// safe because all access happens on the main actor in tests.
private final class TeardownSpy: ControlMasterTearDowning, @unchecked Sendable {
	var registered: [UUID] = []
	var torn: [UUID] = []
	var allCount = 0

	@MainActor
	func register(hostId: UUID, destination: String) {
		registered.append(hostId)
	}

	func tearDown(hostId: UUID) async {
		torn.append(hostId)
	}

	func tearDownAll() async {
		allCount += 1
	}
}

@MainActor
final class ControlMasterTeardownTests: XCTestCase {
	private func makeStore(spy: TeardownSpy) -> SessionStore {
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-cm-teardown-\(UUID()).json")
		let kc = KeychainStore(service: "com.caterm.test.\(UUID())", accessGroup: nil)
		let store = SessionStore(askpassPath: "/dev/null",
		                         knownHostsCaterm: "/dev/null",
		                         knownHostsUser: "/dev/null",
		                         accessGroup: nil,
		                         hostsURL: tmp,
		                         keychain: kc,
		                         controlMasterManager: spy)
		// Tight grace so tests don't drag.
		store.teardownGraceSeconds = 0.05
		return store
	}

	private func makeHost(name: String = "h") -> SSHHost {
		SSHHost(name: name, hostname: "127.0.0.1", port: 22,
		        username: "u", credential: .password)
	}

	/// 100ms > 50ms grace — long enough that a fired teardown will have
	/// run, short enough to keep the test fast.
	private func waitPastGrace() async {
		try? await Task.sleep(nanoseconds: 100_000_000)
	}

	func testNewTabCancelsScheduledTeardown() async {
		let spy = TeardownSpy()
		let store = makeStore(spy: spy)
		let host = makeHost()

		let id1 = store.openTab(host: host)
		store.closeTab(tabId: id1)
		// Open a new tab for the same host within the grace window —
		// this should cancel the pending teardown.
		_ = store.openTab(host: host)

		await waitPastGrace()

		XCTAssertTrue(spy.torn.isEmpty,
		              "teardown should have been cancelled by re-opening a tab")
	}

	func testTeardownFiresAfterGraceWhenNoNewTab() async {
		let spy = TeardownSpy()
		let store = makeStore(spy: spy)
		let host = makeHost()

		let id = store.openTab(host: host)
		store.closeTab(tabId: id)

		await waitPastGrace()

		XCTAssertEqual(spy.torn, [host.id],
		               "last-tab close should tear down ControlMaster after grace")
	}

	func testNonLastTabCloseDoesNotSchedule() async {
		let spy = TeardownSpy()
		let store = makeStore(spy: spy)
		let host = makeHost()

		let id1 = store.openTab(host: host)
		_ = store.openTab(host: host)
		store.closeTab(tabId: id1)

		await waitPastGrace()

		XCTAssertTrue(spy.torn.isEmpty,
		              "closing a non-last tab must not schedule a teardown")
	}
}
