import XCTest
@testable import KeychainStore
@testable import SessionStore
@testable import SSHCommandBuilder

@MainActor
final class SurfaceConfigInstallTerminfoTests: XCTestCase {
	private func makeStore() -> SessionStore {
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-tabs-\(UUID()).json")
		let kc = KeychainStore(service: "com.caterm.test.\(UUID())", accessGroup: nil)
		return SessionStore(askpassPath: "/dev/null",
		                    knownHostsCaterm: "/dev/null",
		                    knownHostsUser: "/dev/null",
		                    accessGroup: nil,
		                    hostsURL: tmp,
		                    keychain: kc)
	}

	private func sampleHost() -> SSHHost {
		SSHHost(name: "test", hostname: "example.com", port: 22,
		        username: "alice", credential: .agent)
	}

	func testOpenTimeDisabledIgnoresLaterEnabledPreference() throws {
		let store = makeStore()
		let tabId = store.openTab(host: sampleHost(), installTerminfo: false)

		guard let cfg = store.surfaceConfig(for: tabId, installTerminfo: true) else {
			XCTFail("surfaceConfig returned nil for a tab we just opened")
			return
		}
		XCTAssertFalse(cfg.command.contains(" -t "), "no -t flag when installTerminfo: false")
		XCTAssertFalse(cfg.env.contains(where: { $0.0 == "TERM" }), "no TERM override when installTerminfo: false")
	}

	func testOpenTimeEnabledIgnoresLaterDisabledPreference() throws {
		let store = makeStore()
		let tabId = store.openTab(host: sampleHost(), installTerminfo: true)

		guard let cfg = store.surfaceConfig(for: tabId, installTerminfo: false) else {
			XCTFail("surfaceConfig returned nil for a tab we just opened")
			return
		}
		XCTAssertTrue(cfg.command.contains(" -t "), "expected -t flag when installTerminfo: true")
		XCTAssertTrue(cfg.env.contains(where: { $0.0 == "TERM" && $0.1 == "xterm-ghostty" }))
	}
}
