import KeychainStore
import SessionStore
import SSHCommandBuilder
import XCTest
@testable import Caterm

@MainActor
final class SessionLivenessProbeTests: XCTestCase {
	func testTimingRejectsNonPositivePollInterval() {
		XCTAssertNil(SessionLivenessProbe.Timing(
			surfacePollInterval: .zero,
			surfaceDiscoveryTimeout: .seconds(3),
			provisionalDelay: .milliseconds(600),
			confirmationDelay: .milliseconds(2_400)
		))
		XCTAssertNil(SessionLivenessProbe.Timing(
			surfacePollInterval: .milliseconds(-1),
			surfaceDiscoveryTimeout: .seconds(3),
			provisionalDelay: .milliseconds(600),
			confirmationDelay: .milliseconds(2_400)
		))
	}

	func testSilentLiveConnectionProgressesThroughTwoPhaseGrace() async {
		let generation = SessionLivenessProbe.Generation(7)
		var preparedSurfaceCount = 0
		var observedSleeps: [Duration] = []
		var observedEvents: [SessionLivenessProbe.Event] = []
		let probe = SessionLivenessProbe(
			expectedGeneration: generation,
			observation: { .surfaceRunning(generation: generation) },
			prepareSurface: { preparedSurfaceCount += 1 },
			sleep: { observedSleeps.append($0) },
			onEvent: { observedEvents.append($0) }
		)

		await probe.run()

		XCTAssertEqual(preparedSurfaceCount, 1)
		XCTAssertEqual(observedSleeps, [.milliseconds(600), .milliseconds(2_400)])
		XCTAssertEqual(observedEvents, [.provisional, .confirmed])
	}

	func testLazySurfaceIsPolledUntilItBecomesAvailable() async throws {
		let generation = SessionLivenessProbe.Generation(3)
		var observations = [
			SessionLivenessProbe.Observation.surfaceUnavailable(generation: generation),
			SessionLivenessProbe.Observation.surfaceUnavailable(generation: generation),
			SessionLivenessProbe.Observation.surfaceRunning(generation: generation),
		]
		var preparedSurfaceCount = 0
		var observedSleeps: [Duration] = []
		var observedEvents: [SessionLivenessProbe.Event] = []
		let timing = try XCTUnwrap(SessionLivenessProbe.Timing(
			surfacePollInterval: .milliseconds(50),
			surfaceDiscoveryTimeout: .seconds(3),
			provisionalDelay: .milliseconds(600),
			confirmationDelay: .milliseconds(2_400)
		))
		let probe = SessionLivenessProbe(
			expectedGeneration: generation,
			timing: timing,
			observation: {
				if observations.count > 1 {
					return observations.removeFirst()
				}
				return observations[0]
			},
			prepareSurface: { preparedSurfaceCount += 1 },
			sleep: { observedSleeps.append($0) },
			onEvent: { observedEvents.append($0) }
		)

		await probe.run()

		XCTAssertEqual(preparedSurfaceCount, 1)
		XCTAssertEqual(
			observedSleeps,
			[.milliseconds(50), .milliseconds(50), .milliseconds(600), .milliseconds(2_400)]
		)
		XCTAssertEqual(observedEvents, [.provisional, .confirmed])
	}

	func testSessionLiveSignalLatchesConfirmationAndStopsGracePath() async {
		let generation = SessionLivenessProbe.Generation(0)
		var observedSleeps: [Duration] = []
		var observedEvents: [SessionLivenessProbe.Event] = []
		var probe: SessionLivenessProbe!
		probe = SessionLivenessProbe(
			expectedGeneration: generation,
			observation: { .surfaceRunning(generation: generation) },
			prepareSurface: {},
			sleep: { duration in
				observedSleeps.append(duration)
				probe.sessionDidBecomeLive()
			},
			onEvent: { observedEvents.append($0) }
		)

		await probe.run()

		XCTAssertEqual(observedSleeps, [.milliseconds(600)])
		XCTAssertEqual(observedEvents, [.confirmed])
	}

	func testConnectionEndEmitsLostAndStopsGracePath() async {
		let generation = SessionLivenessProbe.Generation(0)
		var observedEvents: [SessionLivenessProbe.Event] = []
		var probe: SessionLivenessProbe!
		probe = SessionLivenessProbe(
			expectedGeneration: generation,
			observation: { .surfaceRunning(generation: generation) },
			prepareSurface: {},
			sleep: { _ in probe.connectionDidEnd() },
			onEvent: { observedEvents.append($0) }
		)

		await probe.run()
		probe.sessionDidBecomeLive()

		XCTAssertEqual(observedEvents, [.lost])
	}

	func testTaskCancellationStopsWithoutReportingConnectionLoss() async {
		let generation = SessionLivenessProbe.Generation(0)
		var observedEvents: [SessionLivenessProbe.Event] = []
		let probe = SessionLivenessProbe(
			expectedGeneration: generation,
			observation: { .surfaceRunning(generation: generation) },
			prepareSurface: {},
			sleep: { _ in
				withUnsafeCurrentTask { $0?.cancel() }
			},
			onEvent: { observedEvents.append($0) }
		)

		let task = Task { @MainActor in await probe.run() }
		await task.value

		XCTAssertEqual(observedEvents, [])
	}

	func testGenerationOwnershipLossStopsBeforeProvisionalConnection() async {
		let expectedGeneration = SessionLivenessProbe.Generation(0)
		let replacementGeneration = SessionLivenessProbe.Generation(1)
		var observationCount = 0
		var observedEvents: [SessionLivenessProbe.Event] = []
		let probe = SessionLivenessProbe(
			expectedGeneration: expectedGeneration,
			observation: {
				observationCount += 1
				let generation = observationCount == 1
					? expectedGeneration
					: replacementGeneration
				return .surfaceRunning(generation: generation)
			},
			prepareSurface: {},
			sleep: { _ in },
			onEvent: { observedEvents.append($0) }
		)

		await probe.run()

		XCTAssertEqual(observedEvents, [.lost])
	}

	func testSurfaceDiscoveryExhaustionReportsLoss() async throws {
		let generation = SessionLivenessProbe.Generation(0)
		var observedSleeps: [Duration] = []
		var observedEvents: [SessionLivenessProbe.Event] = []
		let timing = try XCTUnwrap(SessionLivenessProbe.Timing(
			surfacePollInterval: .milliseconds(50),
			surfaceDiscoveryTimeout: .milliseconds(100),
			provisionalDelay: .milliseconds(600),
			confirmationDelay: .milliseconds(2_400)
		))
		let probe = SessionLivenessProbe(
			expectedGeneration: generation,
			timing: timing,
			observation: { .surfaceUnavailable(generation: generation) },
			prepareSurface: {},
			sleep: { observedSleeps.append($0) },
			onEvent: { observedEvents.append($0) }
		)

		await probe.run()

		XCTAssertEqual(observedSleeps, [.milliseconds(50), .milliseconds(50)])
		XCTAssertEqual(observedEvents, [.lost])
	}

	func testExitAfterProvisionalConnectionRemainsAuthenticationFailure() async {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-liveness-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let sessionStore = SessionStore(
			askpassPath: "/tmp/caterm-askpass",
			knownHostsCaterm: "/tmp/caterm-known-hosts",
			knownHostsUser: "/tmp/user-known-hosts",
			accessGroup: nil,
			hostsURL: root.appendingPathComponent("hosts.json"),
			keychain: KeychainStore(service: "test-\(UUID().uuidString)", accessGroup: nil)
		)
		let tabID = sessionStore.openTab(host: SSHHost(
			name: "slow-auth",
			hostname: "example.invalid",
			username: "tester",
			credential: .agent
		))
		let generation = SessionLivenessProbe.Generation(0)
		var observedProvisionalConnection = false
		var probe: SessionLivenessProbe!
		probe = SessionLivenessProbe(
			expectedGeneration: generation,
			observation: { .surfaceRunning(generation: generation) },
			prepareSurface: {},
			sleep: { duration in
				guard duration == .milliseconds(2_400) else { return }
				probe.connectionDidEnd()
				sessionStore.markChildExited(tabId: tabID, exitCode: 255)
			},
			onEvent: { event in
				switch event {
				case .provisional:
					sessionStore.markConnectedProvisional(tabId: tabID)
					if case .connected = sessionStore.tabs.first(where: { $0.id == tabID })?.state {
						observedProvisionalConnection = true
					}
				case .confirmed:
					sessionStore.markConnected(tabId: tabID)
				case .lost:
					break
				}
			}
		)

		await probe.run()

		XCTAssertTrue(observedProvisionalConnection)
		guard case .failed(let failure) = sessionStore.tabs
			.first(where: { $0.id == tabID })?.state else {
			return XCTFail("expected authentication failure after provisional connection")
		}
		XCTAssertEqual(failure, .authOrSetupFail)
	}
}
