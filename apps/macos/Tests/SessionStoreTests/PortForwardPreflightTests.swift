import XCTest
@testable import KeychainStore
@testable import SessionStore
@testable import SSHCommandBuilder

@MainActor
final class PortForwardPreflightTests: XCTestCase {

	/// Test double that lets each test pin a TCP outcome (always `.ok` here so
	/// the forward-preflight path runs) and per-binding `probeLocalBind`
	/// outcomes keyed on `"address:port"`.
	private final class FakePreflight: PreflightProbing, @unchecked Sendable {
		var tcpOutcome: PreflightOutcome = .ok
		var bindOutcomes: [String: PortBindOutcome] = [:]
		var bindProbeKeys: [String] = []
		func probe(host _: String, port _: UInt16, timeout _: TimeInterval) async -> PreflightOutcome {
			tcpOutcome
		}
		func probeLocalBind(address: String, port: UInt16) async -> PortBindOutcome {
			let key = "\(address):\(port)"
			bindProbeKeys.append(key)
			return bindOutcomes[key] ?? .available
		}
	}

	private func makeStore(preflight: PreflightProbing) -> SessionStore {
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-fwd-\(UUID()).json")
		let kc = KeychainStore(service: "com.caterm.test.\(UUID())", accessGroup: nil)
		return SessionStore(askpassPath: "/dev/null",
		                    knownHostsCaterm: "/dev/null",
		                    knownHostsUser: "/dev/null",
		                    accessGroup: nil,
		                    hostsURL: tmp,
		                    keychain: kc,
		                    preflight: preflight)
	}

	private func makeHost(forwards: [PortForward]) -> SSHHost {
		SSHHost(name: "h", hostname: "192.0.2.1", port: 22,
		        username: "u", credential: .password,
		        forwards: forwards)
	}

	private func state(of store: SessionStore, tabId: UUID) -> ConnectionState? {
		store.tabs.first(where: { $0.id == tabId })?.state
	}

	func test_requiredForwardOccupied_failsConnection() async {
		let fake = FakePreflight()
		fake.bindOutcomes["127.0.0.1:5432"] = .unavailable(.alreadyInUse)
		let store = makeStore(preflight: fake)
		let host = makeHost(forwards: [
			PortForward(kind: .local, bindPort: 5432,
			            remoteHost: "db", remotePort: 5432, required: true),
		])
		let tabId = store.openTab(host: host)
		await store.awaitConnectionAttempt(tabId: tabId)
		guard case .failed(.portForwardBindFailed(let fwd, let reason)) = state(of: store, tabId: tabId) else {
			return XCTFail("expected failed(.portForwardBindFailed), got \(String(describing: state(of: store, tabId: tabId)))")
		}
		XCTAssertEqual(fwd.bindPort, 5432)
		XCTAssertEqual(reason, .alreadyInUse)
	}

	func test_optionalForwardOccupied_publishesNoticeAndProceeds() async {
		let fake = FakePreflight()
		fake.bindOutcomes["127.0.0.1:1080"] = .unavailable(.alreadyInUse)
		let store = makeStore(preflight: fake)
		let host = makeHost(forwards: [
			PortForward(kind: .dynamic, bindPort: 1080, required: false),
		])
		let tabId = store.openTab(host: host)
		await store.awaitConnectionAttempt(tabId: tabId)
		XCTAssertEqual(store.skippedForwardNotices.count, 1)
		XCTAssertEqual(store.skippedForwardNotices.first?.hostId, host.id)
		XCTAssertEqual(store.skippedForwardNotices.first?.forward.bindPort, 1080)
		XCTAssertEqual(store.skippedForwardNotices.first?.reason, .alreadyInUse)
		// Should not abort — should advance to .authenticating.
		if case .authenticating = state(of: store, tabId: tabId) { /* ok */ } else {
			XCTFail("optional forward failure must not block connection; got \(String(describing: state(of: store, tabId: tabId)))")
		}
	}

	func test_remoteForward_notProbed() async {
		let fake = FakePreflight()
		// If `remote` forwards were probed, this `.unavailable` outcome would
		// abort the connection (required=true). The test asserts it does not.
		fake.bindOutcomes["127.0.0.1:9090"] = .unavailable(.alreadyInUse)
		let store = makeStore(preflight: fake)
		let host = makeHost(forwards: [
			PortForward(kind: .remote, bindPort: 9090,
			            remoteHost: "localhost", remotePort: 9090, required: true),
		])
		let tabId = store.openTab(host: host)
		await store.awaitConnectionAttempt(tabId: tabId)
		if case .failed(.portForwardBindFailed) = state(of: store, tabId: tabId) {
			XCTFail("remote forwards must not be probed locally")
		}
		XCTAssertTrue(fake.bindProbeKeys.isEmpty,
		              "no local-bind probes should fire for purely-remote forwards")
	}

	func test_staleNotices_clearedOnReconnect() async {
		let fake = FakePreflight()
		fake.bindOutcomes["127.0.0.1:1080"] = .unavailable(.alreadyInUse)
		let store = makeStore(preflight: fake)
		let host = makeHost(forwards: [
			PortForward(kind: .dynamic, bindPort: 1080, required: false),
		])
		let tabId = store.openTab(host: host)
		await store.awaitConnectionAttempt(tabId: tabId)
		XCTAssertEqual(store.skippedForwardNotices.count, 1)

		// Second connection attempt with the same outcome should not double up.
		store.startConnection(tabId: tabId)
		await store.awaitConnectionAttempt(tabId: tabId)
		XCTAssertEqual(store.skippedForwardNotices.count, 1,
		               "stale notices must be cleared before re-populating")
	}
}
