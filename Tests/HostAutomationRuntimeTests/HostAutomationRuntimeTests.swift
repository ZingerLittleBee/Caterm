import XCTest
import SSHCommandBuilder
import SnippetSyncClient
@testable import HostAutomationRuntime

final class HostAutomationRuntimeTests: XCTestCase {
	func testResolverUsesStableSnippetIdentityAndCurrentContent() throws {
		let snippetID = UUID()
		let host = makeHost(
			snippetID: snippetID,
			environment: [
				HostEnvironmentVariable(name: "REGION", value: "west")
			]
		)
		let snippet = makeSnippet(
			id: snippetID,
			name: "Bootstrap",
			content: "printf 'ready\\n'"
		)

		let resolution = HostAutomationResolver.resolve(
			host: host,
			snippets: [snippet]
		)
		let plan = try XCTUnwrap(resolution.plan)

		XCTAssertEqual(plan.startupSnippetID, snippetID)
		XCTAssertEqual(plan.startupSnippetName, "Bootstrap")
		XCTAssertEqual(plan.startupCommand, "printf 'ready\\n'")
		XCTAssertEqual(plan.environment.map(\.name), ["REGION"])
	}

	func testResolverBlocksMissingDeletedAndParameterizedSnippets() {
		let missingID = UUID()
		let host = makeHost(snippetID: missingID)

		XCTAssertEqual(
			HostAutomationResolver.resolve(host: host, snippets: []),
			.unresolved(.missingSnippet(id: missingID))
		)

		let parameterized = makeSnippet(
			id: missingID,
			name: "Deploy",
			content: "deploy {{target}}",
			placeholders: ["target"]
		)
		XCTAssertEqual(
			HostAutomationResolver.resolve(host: host, snippets: [parameterized]),
			.unresolved(
				.snippetRequiresInput(
					id: missingID,
					name: "Deploy",
					placeholders: ["target"]
				)
			)
		)
	}

	func testResolverRejectsEmptyOrInvalidEnabledConfiguration() {
		let emptyID = UUID()
		let emptyHost = makeHost(snippetID: emptyID)
		XCTAssertEqual(
			HostAutomationResolver.resolve(
				host: emptyHost,
				snippets: [makeSnippet(id: emptyID, name: "Empty", content: "  \n")]
			),
			.unresolved(.emptySnippet(id: emptyID, name: "Empty"))
		)

		var invalid = makeHost(snippetID: nil)
		invalid.automation = HostAutomation(
			isEnabled: true,
			environment: [
				HostEnvironmentVariable(name: "1INVALID", value: "value")
			]
		)
		guard case .unresolved(.invalidConfiguration) =
			HostAutomationResolver.resolve(host: invalid, snippets: []) else {
			return XCTFail("Expected invalid configuration")
		}
	}

	func testReviewGateRevealsFullCommandAndCanSuppressAllAutomation() throws {
		let snippetID = UUID()
		let resolution = HostAutomationResolver.resolve(
			host: makeHost(
				snippetID: snippetID,
				environment: [
					HostEnvironmentVariable(name: "REGION", value: "west")
				],
				reviewPolicy: .always
			),
			snippets: [
				makeSnippet(id: snippetID, name: "Bootstrap", content: "echo full-command")
			]
		)
		var controller = HostAutomationSessionController(resolution: resolution)

		guard case .reviewRequired(let plan) = controller.gate else {
			return XCTFail("Expected review gate")
		}
		XCTAssertEqual(plan.startupCommand, "echo full-command")
		XCTAssertFalse(controller.canConnect)

		controller.suppress()

		XCTAssertEqual(controller.gate, .suppressed)
		XCTAssertTrue(controller.canConnect)
		XCTAssertEqual(controller.environment, [])
		XCTAssertNil(controller.startupCommand(sessionGeneration: 1))
	}

	func testApprovalRunsOncePerSessionAcrossReconnects() throws {
		let snippetID = UUID()
		let resolution = HostAutomationResolver.resolve(
			host: makeHost(
				snippetID: snippetID,
				reviewPolicy: .always,
				reconnectPolicy: .oncePerSession
			),
			snippets: [
				makeSnippet(id: snippetID, name: "Bootstrap", content: "echo once")
			]
		)
		var controller = HostAutomationSessionController(resolution: resolution)
		controller.approve()

		XCTAssertEqual(controller.startupCommand(sessionGeneration: 1), "echo once")
		XCTAssertNil(controller.startupCommand(sessionGeneration: 1))
		XCTAssertNil(controller.startupCommand(sessionGeneration: 2))
	}

	func testEveryConnectionRunsOnceForEachDistinctGeneration() {
		let snippetID = UUID()
		let resolution = HostAutomationResolver.resolve(
			host: makeHost(
				snippetID: snippetID,
				reviewPolicy: .never,
				reconnectPolicy: .everyConnection
			),
			snippets: [
				makeSnippet(id: snippetID, name: "Bootstrap", content: "echo reconnect")
			]
		)
		var controller = HostAutomationSessionController(resolution: resolution)

		XCTAssertTrue(controller.canConnect)
		XCTAssertEqual(controller.startupCommand(sessionGeneration: 1), "echo reconnect")
		XCTAssertNil(controller.startupCommand(sessionGeneration: 1))
		XCTAssertEqual(controller.startupCommand(sessionGeneration: 2), "echo reconnect")
		XCTAssertNil(controller.startupCommand(sessionGeneration: 2))
	}

	func testUnresolvedConfigurationCanOnlyConnectAfterExplicitSuppression() {
		let missingID = UUID()
		var controller = HostAutomationSessionController(
			resolution: .unresolved(.missingSnippet(id: missingID))
		)

		XCTAssertEqual(
			controller.gate,
			.blocked(.missingSnippet(id: missingID))
		)
		XCTAssertFalse(controller.canConnect)

		controller.suppress()

		XCTAssertTrue(controller.canConnect)
		XCTAssertEqual(controller.gate, .suppressed)
	}

	func testEnvironmentStatusDoesNotOverstateUnverifiedOrRejectedRequests() {
		let variables = [
			HostEnvironmentVariable(name: "ACCEPTED", value: "one"),
			HostEnvironmentVariable(name: "REJECTED", value: "two"),
		]
		XCTAssertEqual(
			HostEnvironmentRequestStatus.sentUnverified(
				names: variables.map(\.name)
			).isFullyConfigured,
			false
		)
		XCTAssertEqual(
			HostEnvironmentRequestStatus.completed(
				accepted: ["ACCEPTED"],
				rejected: ["REJECTED"]
			).isFullyConfigured,
			false
		)
		XCTAssertTrue(
			HostEnvironmentRequestStatus.completed(
				accepted: ["ACCEPTED", "REJECTED"],
				rejected: []
			).isFullyConfigured
		)
	}

	private func makeHost(
		snippetID: UUID?,
		environment: [HostEnvironmentVariable] = [],
		reviewPolicy: HostAutomationReviewPolicy = .always,
		reconnectPolicy: HostAutomationReconnectPolicy = .oncePerSession
	) -> SSHHost {
		SSHHost(
			name: "Production",
			hostname: "production.example",
			username: "deploy",
			credential: .agent,
			automation: HostAutomation(
				isEnabled: true,
				startupSnippetID: snippetID,
				environment: environment,
				reviewPolicy: reviewPolicy,
				reconnectPolicy: reconnectPolicy
			)
		)
	}

	private func makeSnippet(
		id: UUID,
		name: String,
		content: String,
		placeholders: [String]? = nil
	) -> Snippet {
		Snippet(
			id: id,
			name: name,
			content: content,
			placeholders: placeholders,
			createdAt: Date(timeIntervalSince1970: 0),
			updatedAt: Date(timeIntervalSince1970: 1)
		)
	}
}
