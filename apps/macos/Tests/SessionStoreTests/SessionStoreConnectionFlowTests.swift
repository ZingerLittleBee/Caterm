import XCTest
@testable import KeychainStore
@testable import SessionStore
@testable import SSHCommandBuilder

@MainActor
final class SessionStoreConnectionFlowTests: XCTestCase {

	private final class FakePreflight: PreflightProbing, @unchecked Sendable {
		var nextOutcome: PreflightOutcome = .ok
		var probeCount = 0
		var lastHost: String?
		var lastPort: UInt16?
		func probe(host: String, port: UInt16, timeout: TimeInterval) async -> PreflightOutcome {
			probeCount += 1
			lastHost = host
			lastPort = port
			return nextOutcome
		}
	}

	private func makeStore(preflight: PreflightProbing = FakePreflight()) -> SessionStore {
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-conn-\(UUID()).json")
		let kc = KeychainStore(service: "com.caterm.test.\(UUID())", accessGroup: nil)
		return SessionStore(askpassPath: "/dev/null",
		                    knownHostsCaterm: "/dev/null",
		                    knownHostsUser: "/dev/null",
		                    accessGroup: nil,
		                    hostsURL: tmp,
		                    keychain: kc,
		                    preflight: preflight)
	}

	private func makeHost(port: Int = 22) -> SSHHost {
		SSHHost(name: "h", hostname: "192.0.2.1", port: port,
		        username: "u", credential: .password)
	}

	/// Task 5 tests call `startConnection` EXPLICITLY (not relying on
	/// openTab to wire it — that wiring lands in Task 6). After Task 6,
	/// openTab will also fire its own startConnection; the attempt-token
	/// guard means the explicit call always wins. State-based assertions
	/// (rather than counting probes) keep these tests robust across both
	/// orderings.

	func testStartConnectionSuccessFlow() async {
		let fake = FakePreflight()
		fake.nextOutcome = .ok
		let store = makeStore(preflight: fake)
		let id = store.openTab(host: makeHost())
		store.startConnection(tabId: id)
		await store.awaitConnectionAttempt(tabId: id)
		guard let tab = store.tabs.first(where: { $0.id == id }) else {
			return XCTFail("tab missing")
		}
		if case .authenticating = tab.state { /* ok */ } else {
			XCTFail("expected .authenticating, got \(tab.state)")
		}
		XCTAssertGreaterThanOrEqual(tab.surfaceGeneration, 1,
		    "should bump at least once on a successful auth transition")
	}

	func testStartConnectionDnsFailureFlow() async {
		let fake = FakePreflight()
		fake.nextOutcome = .failed(.dnsFailed)
		let store = makeStore(preflight: fake)
		let id = store.openTab(host: makeHost())
		store.startConnection(tabId: id)
		await store.awaitConnectionAttempt(tabId: id)
		guard let tab = store.tabs.first(where: { $0.id == id }) else {
			return XCTFail("tab missing")
		}
		XCTAssertEqual(tab.state, .failed(.networkUnreachable(.dnsFailed)))
		XCTAssertEqual(tab.surfaceGeneration, 0,
		    "no .ok outcome means no gen bump (placeholder must stay)")
	}

	func testStartConnectionInvalidPortBypassesProbe() async {
		let fake = FakePreflight()
		let store = makeStore(preflight: fake)
		let id = store.openTab(host: makeHost(port: 99999))
		store.startConnection(tabId: id)
		await store.awaitConnectionAttempt(tabId: id)
		guard let tab = store.tabs.first(where: { $0.id == id }) else {
			return XCTFail("tab missing")
		}
		XCTAssertEqual(tab.state, .failed(.networkUnreachable(.invalidPort(99999))))
		XCTAssertEqual(fake.probeCount, 0,
		    "out-of-range port must skip probe in EVERY attempt")
	}

	func testRetryTabResetsStateAndStartsAgain() async {
		let fake = FakePreflight()
		fake.nextOutcome = .failed(.timedOut)
		let store = makeStore(preflight: fake)
		let id = store.openTab(host: makeHost())
		store.startConnection(tabId: id)
		await store.awaitConnectionAttempt(tabId: id)
		XCTAssertEqual(store.tabs.first?.state,
		               .failed(.networkUnreachable(.timedOut)))

		fake.nextOutcome = .ok
		store.retryTab(tabId: id)
		await store.awaitConnectionAttempt(tabId: id)
		guard let tab = store.tabs.first(where: { $0.id == id }) else {
			return XCTFail("tab missing")
		}
		if case .authenticating = tab.state { /* ok */ } else {
			XCTFail("retry should reach .authenticating, got \(tab.state)")
		}
	}

	func testStaleProbeOutcomeDoesNotMutateTabState() async {
		// GatedPreflight parks every probe in a continuations array so the
		// test can resolve them in any order.
		final class GatedPreflight: PreflightProbing, @unchecked Sendable {
			let lock = NSLock()
			var continuations: [CheckedContinuation<PreflightOutcome, Never>] = []
			func probe(host: String, port: UInt16, timeout: TimeInterval) async -> PreflightOutcome {
				await withCheckedContinuation { c in
					lock.lock(); continuations.append(c); lock.unlock()
				}
			}
			func count() -> Int {
				lock.lock(); defer { lock.unlock() }
				return continuations.count
			}
		}
		let gated = GatedPreflight()
		let store = makeStore(preflight: gated)
		let id = store.openTab(host: makeHost())
		store.startConnection(tabId: id)  // attempt 1 — token=1
		store.startConnection(tabId: id)  // attempt 2 — token=2 (supersedes)

		// Wait until both probes are parked.
		let deadline = Date().addingTimeInterval(2)
		while gated.count() < 2, Date() < deadline {
			await Task.yield()
		}
		XCTAssertEqual(gated.count(), 2, "both probes should be in flight")

		// Resolve STALE (token=1) probe first with .ok — must NOT mutate state
		// away from .preflight, because token check fails.
		gated.continuations[0].resume(returning: .ok)
		await Task.yield(); await Task.yield()
		if case .authenticating = store.tabs.first?.state {
			XCTFail("stale .ok must not transition to .authenticating")
		}

		// Resolve CURRENT (token=2) probe with failure — should mutate.
		gated.continuations[1].resume(returning: .failed(.dnsFailed))
		await Task.yield(); await Task.yield()
		XCTAssertEqual(store.tabs.first?.state,
		               .failed(.networkUnreachable(.dnsFailed)),
		               "only the latest attempt's outcome should win")
	}
}
