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
		// openTab fires startConnection → token=1 (Task A, stale).
		// Wait for openTab's probe to be parked before queueing the next one
		// so array indices correspond to token order deterministically.
		let deadline = Date().addingTimeInterval(2)
		while gated.count() < 1, Date() < deadline {
			await Task.yield()
		}
		XCTAssertEqual(gated.count(), 1, "openTab probe should be parked")

		store.startConnection(tabId: id)  // token=2 — cancels Task A, parks Task B (stale)
		while gated.count() < 2, Date() < deadline {
			await Task.yield()
		}
		XCTAssertEqual(gated.count(), 2, "second probe should be parked")

		store.startConnection(tabId: id)  // token=3 — cancels Task B, parks Task C (current)
		while gated.count() < 3, Date() < deadline {
			await Task.yield()
		}
		XCTAssertEqual(gated.count(), 3, "all three probes should be in flight")

		// Resolve STALE probes (token=1 and token=2) with .ok — must NOT mutate
		// state away from .preflight, because token check fails for both.
		gated.continuations[0].resume(returning: .ok)
		gated.continuations[1].resume(returning: .ok)
		await Task.yield(); await Task.yield()
		if case .authenticating = store.tabs.first?.state {
			XCTFail("stale .ok must not transition to .authenticating")
		}

		// Resolve CURRENT (token=3) probe with failure — should mutate.
		gated.continuations[2].resume(returning: .failed(.dnsFailed))
		await Task.yield(); await Task.yield()
		XCTAssertEqual(store.tabs.first?.state,
		               .failed(.networkUnreachable(.dnsFailed)),
		               "only the latest attempt's outcome should win")
	}

	func testStartConnectionCancelsPriorTask() async {
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
		// openTab fires startConnection → Task A (token=1) is queued.
		// Wait for that first probe to be parked.
		let deadline = Date().addingTimeInterval(2)
		while gated.count() < 1, Date() < deadline {
			await Task.yield()
		}
		XCTAssertEqual(gated.count(), 1)

		// Trigger a second start — should cancel Task A (its Task gets
		// cancelled, but the parked continuation in the fake never resumes, so
		// we resolve it manually below).
		store.startConnection(tabId: id)
		while gated.count() < 2, Date() < deadline {
			await Task.yield()
		}
		XCTAssertEqual(gated.count(), 2)

		// Resolve both probes (.ok). Task A was cancelled; its outcome
		// will be discarded both by Task cancellation AND the attempt-token
		// guard. Task B's (token=2) outcome should win.
		gated.continuations[0].resume(returning: .ok)
		gated.continuations[1].resume(returning: .ok)
		await store.awaitConnectionAttempt(tabId: id)
		if case .authenticating = store.tabs.first?.state { /* ok */ } else {
			XCTFail("expected .authenticating after second attempt resolves, got \(store.tabs.first?.state ?? .idle)")
		}
	}

	func testCloseTabCancelsPendingProbe() async {
		final class GatedPreflight: PreflightProbing, @unchecked Sendable {
			let lock = NSLock()
			var probeCount = 0
			func probe(host: String, port: UInt16, timeout: TimeInterval) async -> PreflightOutcome {
				await withCheckedContinuation { (_: CheckedContinuation<PreflightOutcome, Never>) in
					lock.lock(); probeCount += 1; lock.unlock()
					// Park forever — caller should not need to resume; closeTab
					// is expected to cancel the surrounding Task.
				}
			}
		}
		let gated = GatedPreflight()
		let store = makeStore(preflight: gated)
		let id = store.openTab(host: makeHost())
		// openTab now fires startConnection automatically — no explicit call needed.
		// Let the probe park.
		let deadline = Date().addingTimeInterval(2)
		while true {
			gated.lock.lock()
			let c = gated.probeCount
			gated.lock.unlock()
			if c >= 1 || Date() > deadline { break }
			await Task.yield()
		}
		XCTAssertEqual(gated.probeCount, 1)

		// Closing the tab should cancel the in-flight Task; with the parked
		// continuation never resuming, the test would otherwise hang. We assert
		// the test reaches this point and the tab is gone.
		store.closeTab(tabId: id)
		XCTAssertEqual(store.tabs.count, 0)
		// Note: we don't call awaitConnectionAttempt here because closeTab
		// removed the entry from pendingStartTasks; awaitConnectionAttempt
		// would just no-op.
	}

	func testOpenTabFiresStartConnection() async {
		let fake = FakePreflight()
		fake.nextOutcome = .ok
		let store = makeStore(preflight: fake)
		_ = store.openTab(host: makeHost())
		XCTAssertEqual(store.tabs.count, 1)
		// openTab should kick off probe — wait for it.
		await store.awaitConnectionAttempt(tabId: store.tabs[0].id)
		XCTAssertEqual(fake.probeCount, 1)
	}

	func testReconnectTimerGoesThroughPreflight() async {
		// Force the FSM into .reconnecting by calling markChildExited from a
		// .connected state on a tab that already had hadConnected=true.
		let fake = FakePreflight()
		fake.nextOutcome = .ok
		let store = makeStore(preflight: fake)
		let id = store.openTab(host: makeHost())
		await store.awaitConnectionAttempt(tabId: id)
		store.markConnected(tabId: id)

		// Trigger reconnect path: ssh exits with non-zero AFTER hadConnected=true
		// → FailureKind.connectionDropped → scheduleReconnect (1s backoff).
		store.markChildExited(tabId: id, exitCode: 1) // -> .reconnecting

		// Wait until the probe count rises above the initial open's count.
		let deadline = Date().addingTimeInterval(6)
		while fake.probeCount < 2, Date() < deadline {
			try? await Task.sleep(nanoseconds: 100_000_000)
		}
		XCTAssertGreaterThanOrEqual(fake.probeCount, 2,
			"scheduleReconnect should route through startConnection")
	}
}
