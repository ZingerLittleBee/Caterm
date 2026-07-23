import XCTest
import HostAutomationRuntime
@testable import KeychainStore
@testable import SessionStore
@testable import SSHCommandBuilder

@MainActor
final class SessionAutomationTests: XCTestCase {
	private final class FakePreflight: PreflightProbing, @unchecked Sendable {
		var probeCount = 0

		func probe(
			host _: String,
			port _: UInt16,
			timeout _: TimeInterval
		) async -> PreflightOutcome {
			probeCount += 1
			return .ok
		}

		func probeLocalBind(
			address _: String,
			port _: UInt16
		) async -> PortBindOutcome {
			.available
		}
	}

	func testReviewRequiredPreventsConnectionUntilApproved() async throws {
		let fake = FakePreflight()
		let store = makeStore(preflight: fake)
		let plan = makePlan(reviewPolicy: .always)

		let tabID = store.openTab(
			host: makeHost(),
			automationResolution: .ready(plan)
		)

		XCTAssertEqual(store.automationGate(for: tabID), .reviewRequired(plan))
		XCTAssertEqual(fake.probeCount, 0)
		XCTAssertEqual(store.tabs.first?.surfaceGeneration, 0)

		store.approveAutomation(tabId: tabID)
		await store.awaitConnectionAttempt(tabId: tabID)

		XCTAssertEqual(store.automationGate(for: tabID), .approved(plan))
		XCTAssertEqual(fake.probeCount, 1)
		XCTAssertEqual(store.tabs.first?.surfaceGeneration, 1)
	}

	func testSuppressionConnectsWithoutStartupCommandOrSetEnv() async throws {
		let fake = FakePreflight()
		let store = makeStore(preflight: fake)
		let tabID = store.openTab(
			host: makeHost(),
			automationResolution: .ready(makePlan(reviewPolicy: .always))
		)

		store.suppressAutomation(tabId: tabID)
		await store.awaitConnectionAttempt(tabId: tabID)
		let config = try XCTUnwrap(store.surfaceConfig(for: tabID))

		XCTAssertEqual(store.automationGate(for: tabID), .suppressed)
		XCTAssertFalse(config.command.contains("SetEnv="))
		XCTAssertNil(store.consumeStartupCommand(tabId: tabID, generation: 1))
	}

	func testStartupCommandIsConsumedExactlyOnceUsingSurfaceGeneration() async throws {
		let store = makeStore()
		let tabID = store.openTab(
			host: makeHost(),
			automationResolution: .ready(
				makePlan(
					reviewPolicy: .never,
					reconnectPolicy: .everyConnection
				)
			)
		)
		await store.awaitConnectionAttempt(tabId: tabID)
		let firstGeneration = try XCTUnwrap(
			store.tabs.first(where: { $0.id == tabID })?.surfaceGeneration
		)

		XCTAssertEqual(
			store.consumeStartupCommand(
				tabId: tabID,
				generation: firstGeneration
			),
			"printf 'ready\\n'"
		)
		XCTAssertNil(store.consumeStartupCommand(
			tabId: tabID,
			generation: firstGeneration
		))
		store.retryTab(tabId: tabID)
		await store.awaitConnectionAttempt(tabId: tabID)
		let secondGeneration = try XCTUnwrap(
			store.tabs.first(where: { $0.id == tabID })?.surfaceGeneration
		)
		XCTAssertGreaterThan(secondGeneration, firstGeneration)
		XCTAssertEqual(
			store.consumeStartupCommand(
				tabId: tabID,
				generation: secondGeneration
			),
			"printf 'ready\\n'"
		)
	}

	func testOpenSSHEnvironmentStatusRemainsUnverifiedAfterSessionIsLive() async throws {
		let store = makeStore()
		let tabID = store.openTab(
			host: makeHost(),
			automationResolution: .ready(makePlan(reviewPolicy: .never))
		)
		await store.awaitConnectionAttempt(tabId: tabID)
		let generation = try XCTUnwrap(
			store.tabs.first(where: { $0.id == tabID })?.surfaceGeneration
		)

		store.markAutomationSessionLive(
			tabId: tabID,
			generation: generation
		)

		XCTAssertEqual(
			store.environmentRequestStatus(for: tabID),
			.sentUnverified(names: ["REGION"])
		)
		XCTAssertFalse(
			store.environmentRequestStatus(for: tabID)?.isFullyConfigured ?? true
		)
	}

	func testStaleSurfaceCannotMarkEnvironmentOrConsumeStartupCommand() async throws {
		let store = makeStore()
		let tabID = store.openTab(
			host: makeHost(),
			automationResolution: .ready(
				makePlan(
					reviewPolicy: .never,
					reconnectPolicy: .everyConnection
				)
			)
		)
		await store.awaitConnectionAttempt(tabId: tabID)
		let firstGeneration = try XCTUnwrap(
			store.tabs.first(where: { $0.id == tabID })?.surfaceGeneration
		)

		store.retryTab(tabId: tabID)
		await store.awaitConnectionAttempt(tabId: tabID)
		let secondGeneration = try XCTUnwrap(
			store.tabs.first(where: { $0.id == tabID })?.surfaceGeneration
		)
		XCTAssertGreaterThan(secondGeneration, firstGeneration)

		store.markAutomationSessionLive(
			tabId: tabID,
			generation: firstGeneration
		)
		XCTAssertEqual(
			store.environmentRequestStatus(for: tabID),
			.pending(names: ["REGION"])
		)
		XCTAssertNil(store.consumeStartupCommand(
			tabId: tabID,
			generation: firstGeneration
		))
		XCTAssertEqual(
			store.consumeStartupCommand(
				tabId: tabID,
				generation: secondGeneration
			),
			"printf 'ready\\n'"
		)
	}

	func testMissingSnippetRequiresExplicitConnectWithoutAutomation() async {
		let fake = FakePreflight()
		let store = makeStore(preflight: fake)
		let reason = HostAutomationUnresolvedReason.missingSnippet(id: UUID())
		let tabID = store.openTab(
			host: makeHost(),
			automationResolution: .unresolved(reason)
		)

		XCTAssertEqual(store.automationGate(for: tabID), .blocked(reason))
		XCTAssertEqual(fake.probeCount, 0)

		store.suppressAutomation(tabId: tabID)
		await store.awaitConnectionAttempt(tabId: tabID)

		XCTAssertEqual(fake.probeCount, 1)
	}

	func testAutomationApprovalCannotBypassBrokenJumpHostFailure() async {
		let fake = FakePreflight()
		let store = makeStore(preflight: fake)
		var host = makeHost()
		host.jumpHostId = UUID()
		let plan = makePlan(reviewPolicy: .always)

		let tabID = store.openTab(
			host: host,
			automationResolution: .ready(plan)
		)
		guard case .failed = store.tabs.first?.state else {
			return XCTFail("Expected the broken jump Host to fail before review")
		}

		store.approveAutomation(tabId: tabID)
		await Task.yield()

		XCTAssertEqual(store.automationGate(for: tabID), .reviewRequired(plan))
		XCTAssertEqual(fake.probeCount, 0)
		XCTAssertEqual(store.tabs.first?.surfaceGeneration, 0)
	}

	private func makeStore(
		preflight: PreflightProbing = FakePreflight()
	) -> SessionStore {
		SessionStore(
			askpassPath: "/dev/null",
			knownHostsCaterm: "/dev/null",
			knownHostsUser: "/dev/null",
			accessGroup: nil,
			hostsURL: FileManager.default.temporaryDirectory
				.appendingPathComponent("session-automation-\(UUID()).json"),
			keychain: KeychainStore(
				service: "com.caterm.test.session-automation.\(UUID())",
				accessGroup: nil
			),
			preflight: preflight
		)
	}

	private func makeHost() -> SSHHost {
		SSHHost(
			name: "Production",
			hostname: "192.0.2.1",
			username: "deploy",
			credential: .password,
			automation: HostAutomation(
				isEnabled: true,
				startupSnippetID: UUID(),
				environment: [
					HostEnvironmentVariable(name: "REGION", value: "west")
				]
			)
		)
	}

	private func makePlan(
		reviewPolicy: HostAutomationReviewPolicy,
		reconnectPolicy: HostAutomationReconnectPolicy = .oncePerSession
	) -> HostAutomationSessionPlan {
		HostAutomationSessionPlan(
			startupSnippetID: UUID(),
			startupSnippetName: "Bootstrap",
			startupCommand: "printf 'ready\\n'",
			environment: [
				HostEnvironmentVariable(name: "REGION", value: "west")
			],
			reviewPolicy: reviewPolicy,
			reconnectPolicy: reconnectPolicy
		)
	}
}
