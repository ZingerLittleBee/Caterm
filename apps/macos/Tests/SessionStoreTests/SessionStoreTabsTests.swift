import XCTest
@testable import SessionStore
@testable import SSHCommandBuilder

@MainActor
final class SessionStoreTabsTests: XCTestCase {
	private func makeStore() -> SessionStore {
		SessionStore(askpassPath: "/dev/null",
		             knownHostsCaterm: "/dev/null",
		             knownHostsUser: "/dev/null",
		             accessGroup: nil)
	}

	private func makeHost(name: String = "h") -> SSHHost {
		SSHHost(name: name, hostname: "127.0.0.1", port: 22,
		        username: "u", credential: .password)
	}

	func testOpenTabAppends() {
		let store = makeStore()
		let id = store.openTab(host: makeHost())
		XCTAssertEqual(store.tabs.count, 1)
		XCTAssertEqual(store.tabs.first?.id, id)
	}

	func testCloseTabRemovesById() {
		let store = makeStore()
		let id1 = store.openTab(host: makeHost(name: "a"))
		let id2 = store.openTab(host: makeHost(name: "b"))
		XCTAssertEqual(store.tabs.count, 2)

		store.closeTab(tabId: id1)
		XCTAssertEqual(store.tabs.count, 1)
		XCTAssertEqual(store.tabs.first?.id, id2)
	}

	func testCloseTabUnknownIdNoop() {
		let store = makeStore()
		_ = store.openTab(host: makeHost())
		store.closeTab(tabId: UUID())
		XCTAssertEqual(store.tabs.count, 1)
	}

	func testCloseTabAllTabs() {
		let store = makeStore()
		let id1 = store.openTab(host: makeHost(name: "a"))
		let id2 = store.openTab(host: makeHost(name: "b"))
		store.closeTab(tabId: id1)
		store.closeTab(tabId: id2)
		XCTAssertTrue(store.tabs.isEmpty)
	}
}
