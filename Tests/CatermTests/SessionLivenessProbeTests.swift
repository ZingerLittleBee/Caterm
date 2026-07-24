import AppKit
import FileTransferStore
import HostAutomationRuntime
import KeychainStore
import SessionStore
import SettingsStore
import SSHCommandBuilder
import SwiftUI
import TerminalEngine
import XCTest
@testable import Caterm

@MainActor
final class SessionLivenessProbeTests: XCTestCase {
	private final class ImmediatePreflight:
		PreflightProbing, @unchecked Sendable {
		func probe(
			host _: String,
			port _: UInt16,
			timeout _: TimeInterval
		) async -> PreflightOutcome {
			.ok
		}

		func probeLocalBind(
			address _: String,
			port _: UInt16
		) async -> PortBindOutcome {
			.available
		}
	}

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

	func testSilentLiveConfirmationRunsStartupCommandExactlyOnce() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-silent-automation-\(UUID())")
		let sessionStore = SessionStore(
			askpassPath: "/tmp/caterm-askpass",
			knownHostsCaterm: "/tmp/caterm-known-hosts",
			knownHostsUser: "/tmp/user-known-hosts",
			accessGroup: nil,
			hostsURL: root.appendingPathComponent("hosts.json"),
			keychain: KeychainStore(
				service: "com.caterm.test.silent-automation.\(UUID())",
				accessGroup: nil
			),
			preflight: ImmediatePreflight()
		)
		let plan = HostAutomationSessionPlan(
			startupSnippetID: UUID(),
			startupSnippetName: "Bootstrap",
			startupCommand: "printf 'silent-ready\\n'",
			environment: [
				HostEnvironmentVariable(name: "REGION", value: "west")
			],
			reviewPolicy: .never,
			reconnectPolicy: .everyConnection
		)
		let tabID = sessionStore.openTab(
			host: SSHHost(
				name: "Silent",
				hostname: "192.0.2.1",
				username: "deploy",
				credential: .agent
			),
			automationResolution: .ready(plan)
		)
		await sessionStore.awaitConnectionAttempt(tabId: tabID)
		let generation = try XCTUnwrap(
			sessionStore.tabs.first(where: { $0.id == tabID })?
				.surfaceGeneration
		)
		let expectedGeneration = SessionLivenessProbe.Generation(generation)
		var commands: [String] = []
		let probe = SessionLivenessProbe(
			expectedGeneration: expectedGeneration,
			observation: {
				.surfaceRunning(generation: expectedGeneration)
			},
			prepareSurface: {},
			sleep: { _ in },
			onEvent: { event in
				guard event == .confirmed else { return }
				HostAutomationLiveSessionActivator.activate(
					store: sessionStore,
					tabID: tabID,
					generation: generation,
					execute: { commands.append($0) }
				)
			}
		)

		await probe.run()
		HostAutomationLiveSessionActivator.activate(
			store: sessionStore,
			tabID: tabID,
			generation: generation,
			execute: { commands.append($0) }
		)

		XCTAssertEqual(commands, ["printf 'silent-ready\\n'"])
		XCTAssertEqual(
			sessionStore.environmentRequestStatus(for: tabID),
			.sentUnverified(names: ["REGION"])
		)
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

	func testProductionSurfaceExitMovesConnectedSessionToCleanExit() async throws {
		guard await childExitLocalSSHAvailable() else {
			throw XCTSkip("Local SSH is unavailable on this host.")
		}
		_ = NSApplication.shared
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-child-exit-\(UUID())")
		try FileManager.default.createDirectory(
			at: root,
			withIntermediateDirectories: true
		)
		let sessionStore = SessionStore(
			askpassPath: "/dev/null",
			knownHostsCaterm: root.appendingPathComponent("known_hosts").path,
			knownHostsUser: "/dev/null",
			accessGroup: nil,
			hostsURL: root.appendingPathComponent("hosts.json"),
			keychain: KeychainStore(
				service: "com.caterm.test.child-exit.\(UUID())",
				accessGroup: nil
			),
			controlMasterManager: ControlMasterManager.shared,
			preflight: ImmediatePreflight()
		)
		let tabID = sessionStore.openTab(host: SSHHost(
			name: "Child Exit",
			hostname: "localhost",
			username: NSUserName(),
			credential: .agent
		))
		await sessionStore.awaitConnectionAttempt(tabId: tabID)
		let registry = SurfaceRegistry()
		let settingsStore = SettingsStore(
			settings: .empty,
			path: root.appendingPathComponent("settings.plist")
		)
		let rootView = TerminalContainerView(tabId: tabID)
			.environmentObject(sessionStore)
			.environmentObject(settingsStore)
			.environmentObject(registry)
		let hostingView = NSHostingView(rootView: rootView)
		let window = NSWindow(
			contentRect: CGRect(x: 0, y: 0, width: 640, height: 400),
			styleMask: [.titled, .resizable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = hostingView
		window.makeKeyAndOrderFront(nil)
		addTeardownBlock { @MainActor in
			sessionStore.closeTab(tabId: tabID)
			window.contentView = nil
			window.close()
			await ControlMasterManager.shared.tearDownAll()
			try? FileManager.default.removeItem(at: root)
		}

		let surfaceDiscovered = try await waitUntil {
			registry.surface(for: tabID) != nil
		}
		XCTAssertTrue(surfaceDiscovered, "production surface was not registered")
		let connected = try await waitUntil(timeout: 8) {
			guard let tab = sessionStore.tabs.first(where: { $0.id == tabID })
			else { return false }
			if case .connected = tab.state, tab.hadConnected { return true }
			return false
		}
		XCTAssertTrue(connected, "local SSH session did not connect")

		let surface = try XCTUnwrap(registry.surface(for: tabID))
		surface.setFocus(true)
		try await Task.sleep(for: .seconds(1))
		let inputMarker = root.appendingPathComponent("input-ready")
		surface.run("printf ready > '\(inputMarker.path)'")
		let inputDelivered = try await waitUntil {
			FileManager.default.fileExists(atPath: inputMarker.path)
		}
		XCTAssertTrue(inputDelivered, "production surface did not deliver input")
		surface.run("exit")

		let childExitReported = try await waitUntil {
			surface.processExited
		}
		XCTAssertTrue(
			childExitReported,
			"libghostty did not report the exited PTY child"
		)
		let exited = try await waitUntil {
			guard let tab = sessionStore.tabs.first(where: { $0.id == tabID })
			else { return false }
			return tab.state == .failed(.cleanExit)
		}
		XCTAssertTrue(
			exited,
			"exited PTY child left the production session marked connected"
		)
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

@MainActor
private func waitUntil(
	timeout: TimeInterval = 5,
	condition: @MainActor () -> Bool
) async throws -> Bool {
	let deadline = Date().addingTimeInterval(timeout)
	while !condition() {
		guard Date() < deadline else { return false }
		try await Task.sleep(for: .milliseconds(50))
	}
	return true
}

private func childExitLocalSSHAvailable() async -> Bool {
	await Task.detached {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
		process.arguments = [
			"-o", "BatchMode=yes",
			"-o", "ConnectTimeout=3",
			"-o", "StrictHostKeyChecking=no",
			"-o", "UserKnownHostsFile=/dev/null",
			"-o", "LogLevel=ERROR",
			"localhost", "true",
		]
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
			process.waitUntilExit()
			return process.terminationStatus == 0
		} catch {
			return false
		}
	}.value
}
