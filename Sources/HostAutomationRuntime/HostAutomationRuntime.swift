import Foundation
import SSHCommandBuilder
import SnippetSyncClient

public struct HostAutomationSnippet: Equatable, Sendable {
	public let id: UUID
	public let name: String
	public let content: String
	public let placeholders: [String]

	public init(
		id: UUID,
		name: String,
		content: String,
		placeholders: [String] = []
	) {
		self.id = id
		self.name = name
		self.content = content
		self.placeholders = placeholders
	}
}

public struct HostAutomationSessionPlan: Equatable, Sendable {
	public let startupSnippetID: UUID?
	public let startupSnippetName: String?
	public let startupCommand: String?
	public let environment: [HostEnvironmentVariable]
	public let reviewPolicy: HostAutomationReviewPolicy
	public let reconnectPolicy: HostAutomationReconnectPolicy

	public init(
		startupSnippetID: UUID?,
		startupSnippetName: String?,
		startupCommand: String?,
		environment: [HostEnvironmentVariable],
		reviewPolicy: HostAutomationReviewPolicy,
		reconnectPolicy: HostAutomationReconnectPolicy
	) {
		self.startupSnippetID = startupSnippetID
		self.startupSnippetName = startupSnippetName
		self.startupCommand = startupCommand
		self.environment = environment
		self.reviewPolicy = reviewPolicy
		self.reconnectPolicy = reconnectPolicy
	}
}

public enum HostAutomationUnresolvedReason: Equatable, Sendable {
	case missingSnippet(id: UUID)
	case snippetRequiresInput(id: UUID, name: String, placeholders: [String])
	case emptySnippet(id: UUID, name: String)
	case invalidConfiguration(message: String)

	public var message: String {
		switch self {
		case .missingSnippet:
			"The startup snippet is unavailable. Edit the Host or connect without automation."
		case .snippetRequiresInput(_, let name, let placeholders):
			"\(name) requires values for \(placeholders.joined(separator: ", ")). Choose a snippet without placeholders."
		case .emptySnippet(_, let name):
			"\(name) has no command to run. Edit the snippet or remove it from the Host."
		case .invalidConfiguration(let message):
			message
		}
	}
}

public enum HostAutomationResolution: Equatable, Sendable {
	case disabled
	case ready(HostAutomationSessionPlan)
	case unresolved(HostAutomationUnresolvedReason)

	public var plan: HostAutomationSessionPlan? {
		guard case .ready(let plan) = self else { return nil }
		return plan
	}
}

public enum HostAutomationResolver {
	public static func resolve(
		host: SSHHost,
		snippets: [Snippet]
	) -> HostAutomationResolution {
		resolve(
			host: host,
			automationSnippets: snippets.map {
				HostAutomationSnippet(
					id: $0.id,
					name: $0.name,
					content: $0.content,
					placeholders: $0.placeholders ?? []
				)
			}
		)
	}

	public static func resolve(
		host: SSHHost,
		automationSnippets snippets: [HostAutomationSnippet]
	) -> HostAutomationResolution {
		guard host.automation.isEnabled else { return .disabled }

		let automation: HostAutomation
		do {
			automation = try host.automation.validated()
		} catch {
			return .unresolved(
				.invalidConfiguration(
					message: (error as? LocalizedError)?.errorDescription
						?? String(describing: error)
				)
			)
		}

		guard let snippetID = automation.startupSnippetID else {
			return .ready(plan(for: automation, snippet: nil))
		}
		guard let snippet = snippets.first(where: { $0.id == snippetID }) else {
			return .unresolved(.missingSnippet(id: snippetID))
		}
		if !snippet.placeholders.isEmpty {
			return .unresolved(
				.snippetRequiresInput(
					id: snippetID,
					name: snippet.name,
					placeholders: snippet.placeholders
				)
			)
		}
		guard !snippet.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return .unresolved(.emptySnippet(id: snippetID, name: snippet.name))
		}
		return .ready(plan(for: automation, snippet: snippet))
	}

	private static func plan(
		for automation: HostAutomation,
		snippet: HostAutomationSnippet?
	) -> HostAutomationSessionPlan {
		HostAutomationSessionPlan(
			startupSnippetID: snippet?.id,
			startupSnippetName: snippet?.name,
			startupCommand: snippet?.content,
			environment: automation.environment,
			reviewPolicy: automation.reviewPolicy,
			reconnectPolicy: automation.reconnectPolicy
		)
	}
}

public enum HostAutomationConnectionGate: Equatable, Sendable {
	case inactive
	case reviewRequired(HostAutomationSessionPlan)
	case approved(HostAutomationSessionPlan)
	case blocked(HostAutomationUnresolvedReason)
	case suppressed
}

public struct HostAutomationSessionController: Equatable, Sendable {
	public private(set) var gate: HostAutomationConnectionGate
	private var executedGenerations: Set<Int> = []
	private var didExecuteInSession = false

	public init(resolution: HostAutomationResolution) {
		switch resolution {
		case .disabled:
			gate = .inactive
		case .ready(let plan) where plan.reviewPolicy == .always:
			gate = .reviewRequired(plan)
		case .ready(let plan):
			gate = .approved(plan)
		case .unresolved(let reason):
			gate = .blocked(reason)
		}
	}

	public var canConnect: Bool {
		switch gate {
		case .inactive, .approved, .suppressed:
			true
		case .reviewRequired, .blocked:
			false
		}
	}

	public var environment: [HostEnvironmentVariable] {
		guard case .approved(let plan) = gate else { return [] }
		return plan.environment
	}

	public mutating func approve() {
		guard case .reviewRequired(let plan) = gate else { return }
		gate = .approved(plan)
	}

	public mutating func suppress() {
		switch gate {
		case .reviewRequired, .blocked, .approved:
			gate = .suppressed
		case .inactive, .suppressed:
			break
		}
	}

	public mutating func startupCommand(
		sessionGeneration: Int
	) -> String? {
		guard case .approved(let plan) = gate,
		      let command = plan.startupCommand else {
			return nil
		}
		switch plan.reconnectPolicy {
		case .oncePerSession:
			guard !didExecuteInSession else { return nil }
			didExecuteInSession = true
			return command
		case .everyConnection:
			guard executedGenerations.insert(sessionGeneration).inserted else {
				return nil
			}
			return command
		}
	}
}

public enum HostEnvironmentRequestStatus: Equatable, Sendable {
	case notRequested
	case pending(names: [String])
	case sentUnverified(names: [String])
	case completed(accepted: [String], rejected: [String])

	public var isFullyConfigured: Bool {
		switch self {
		case .notRequested:
			true
		case .pending, .sentUnverified:
			false
		case .completed(_, let rejected):
			rejected.isEmpty
		}
	}
}
