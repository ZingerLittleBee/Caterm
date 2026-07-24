import Combine
import Foundation
import WorkspaceCore

public enum WorkspaceBroadcastSource: Equatable, Sendable {
	case command(String)
	case snippet(id: UUID, name: String, text: String)

	public var text: String {
		switch self {
		case .command(let text):
			text
		case .snippet(_, _, let text):
			text
		}
	}

	public var label: String {
		switch self {
		case .command:
			"Reviewed Command"
		case .snippet(_, let name, _):
			"Snippet: \(name)"
		}
	}
}

public struct WorkspaceBroadcastRecipient: Identifiable, Hashable, Sendable {
	public var id: PaneID { paneID }
	public let workspaceID: WorkspaceID
	public let paneID: PaneID
	public let sessionID: UUID
	public let surfaceLeaseID: UUID
	public let paneLabel: String
	public let hostName: String
	public let address: String

	public init(
		workspaceID: WorkspaceID,
		paneID: PaneID,
		sessionID: UUID,
		surfaceLeaseID: UUID,
		paneLabel: String,
		hostName: String,
		address: String
	) {
		self.workspaceID = workspaceID
		self.paneID = paneID
		self.sessionID = sessionID
		self.surfaceLeaseID = surfaceLeaseID
		self.paneLabel = paneLabel
		self.hostName = hostName
		self.address = address
	}
}

public enum WorkspaceBroadcastError: Error, Equatable, LocalizedError {
	case emptyCommand
	case requiresTwoRecipients
	case crossWorkspaceRecipient
	case duplicateRecipient

	public var errorDescription: String? {
		switch self {
		case .emptyCommand:
			"Enter a complete command or choose a non-empty snippet."
		case .requiresTwoRecipients:
			"Select at least two connected terminal Panes."
		case .crossWorkspaceRecipient:
			"Broadcast recipients must belong to this Workspace window."
		case .duplicateRecipient:
			"Each terminal Pane can receive the command only once."
		}
	}
}

public struct WorkspaceBroadcastPlan: Identifiable, Equatable, Sendable {
	public let id: UUID
	public let workspaceID: WorkspaceID
	public let source: WorkspaceBroadcastSource
	public let recipients: [WorkspaceBroadcastRecipient]
	public let armedAt: Date

	public init(
		id: UUID = UUID(),
		workspaceID: WorkspaceID,
		source: WorkspaceBroadcastSource,
		recipients: [WorkspaceBroadcastRecipient],
		armedAt: Date = Date()
	) throws {
		guard !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw WorkspaceBroadcastError.emptyCommand
		}
		guard recipients.count >= 2 else {
			throw WorkspaceBroadcastError.requiresTwoRecipients
		}
		guard recipients.allSatisfy({ $0.workspaceID == workspaceID }) else {
			throw WorkspaceBroadcastError.crossWorkspaceRecipient
		}
		guard Set(recipients.map(\.paneID)).count == recipients.count,
		      Set(recipients.map(\.sessionID)).count == recipients.count else {
			throw WorkspaceBroadcastError.duplicateRecipient
		}
		self.id = id
		self.workspaceID = workspaceID
		self.source = source
		self.recipients = recipients
		self.armedAt = armedAt
	}
}

public enum WorkspaceBroadcastIneligibility: Equatable, Sendable {
	case missing
	case disconnected
	case surfaceReplaced
	case stopped

	public var description: String {
		switch self {
		case .missing:
			"Pane or session is no longer available"
		case .disconnected:
			"Terminal disconnected before delivery"
		case .surfaceReplaced:
			"Terminal reconnected after arming"
		case .stopped:
			"Broadcast stopped before delivery"
		}
	}
}

public enum WorkspaceBroadcastEligibility: Equatable, Sendable {
	case eligible
	case missing
	case disconnected
	case surfaceReplaced

	var ineligibility: WorkspaceBroadcastIneligibility? {
		switch self {
		case .eligible:
			nil
		case .missing:
			.missing
		case .disconnected:
			.disconnected
		case .surfaceReplaced:
			.surfaceReplaced
		}
	}
}

public enum WorkspaceBroadcastOutcomeStatus: Equatable, Sendable {
	case delivered
	case skipped(WorkspaceBroadcastIneligibility)
	case failed(String)
}

public struct WorkspaceBroadcastOutcome: Identifiable, Equatable, Sendable {
	public var id: PaneID { recipient.id }
	public let recipient: WorkspaceBroadcastRecipient
	public let status: WorkspaceBroadcastOutcomeStatus

	public init(
		recipient: WorkspaceBroadcastRecipient,
		status: WorkspaceBroadcastOutcomeStatus
	) {
		self.recipient = recipient
		self.status = status
	}
}

public struct WorkspaceBroadcastReport: Identifiable, Equatable, Sendable {
	public var id: UUID { plan.id }
	public let plan: WorkspaceBroadcastPlan
	public let outcomes: [WorkspaceBroadcastOutcome]
	public let completedAt: Date

	public init(
		plan: WorkspaceBroadcastPlan,
		outcomes: [WorkspaceBroadcastOutcome],
		completedAt: Date = Date()
	) {
		self.plan = plan
		self.outcomes = outcomes
		self.completedAt = completedAt
	}
}

public enum WorkspaceBroadcastPhase: Equatable, Sendable {
	case idle
	case armed(WorkspaceBroadcastPlan)
	case delivering(WorkspaceBroadcastPlan)
}

public enum WorkspaceBroadcastReconciliation: Equatable, Sendable {
	case unchanged
	case disarmed
	case stoppingDelivery
}

@MainActor
public final class WorkspaceBroadcastSession: ObservableObject {
	@Published public private(set) var phase: WorkspaceBroadcastPhase = .idle
	@Published public private(set) var latestReport: WorkspaceBroadcastReport?
	private var stopRequested = false

	public init() {}

	public var activePlan: WorkspaceBroadcastPlan? {
		switch phase {
		case .idle:
			nil
		case .armed(let plan), .delivering(let plan):
			plan
		}
	}

	public var canDeliver: Bool {
		guard case .armed = phase else { return false }
		return true
	}

	public var isDelivering: Bool {
		guard case .delivering = phase else { return false }
		return true
	}

	public func arm(_ plan: WorkspaceBroadcastPlan) {
		guard case .idle = phase else { return }
		stopRequested = false
		latestReport = nil
		phase = .armed(plan)
	}

	public func stop() {
		switch phase {
		case .idle:
			break
		case .armed:
			stopRequested = true
			phase = .idle
		case .delivering:
			stopRequested = true
		}
	}

	@discardableResult
	public func reconcileEligibility(
		_ eligibility: (WorkspaceBroadcastRecipient) -> WorkspaceBroadcastEligibility
	) -> WorkspaceBroadcastReconciliation {
		let plan: WorkspaceBroadcastPlan
		let isDelivering: Bool
		switch phase {
		case .idle:
			return .unchanged
		case .armed(let armedPlan):
			plan = armedPlan
			isDelivering = false
		case .delivering(let deliveringPlan):
			plan = deliveringPlan
			isDelivering = true
		}
		let eligibleCount = plan.recipients.reduce(into: 0) { count, recipient in
			if eligibility(recipient) == .eligible { count += 1 }
		}
		guard eligibleCount < 2 else { return .unchanged }
		stopRequested = true
		if isDelivering {
			return .stoppingDelivery
		}
		phase = .idle
		return .disarmed
	}

	public func deliver(
		eligibility: @MainActor (WorkspaceBroadcastRecipient) -> WorkspaceBroadcastEligibility,
		send: @MainActor (WorkspaceBroadcastRecipient, String) async throws -> Void
	) async {
		guard case .armed(let plan) = phase else { return }
		stopRequested = false
		phase = .delivering(plan)
		var outcomes: [WorkspaceBroadcastOutcome] = []

		for recipient in plan.recipients {
			await Task.yield()
			if stopRequested {
				let reason = eligibility(recipient).ineligibility ?? .stopped
				outcomes.append(WorkspaceBroadcastOutcome(
					recipient: recipient,
					status: .skipped(reason)
				))
				continue
			}
			let currentEligibility = eligibility(recipient)
			if let ineligibility = currentEligibility.ineligibility {
				outcomes.append(WorkspaceBroadcastOutcome(
					recipient: recipient,
					status: .skipped(ineligibility)
				))
				continue
			}
			do {
				try await send(recipient, plan.source.text)
				outcomes.append(WorkspaceBroadcastOutcome(
					recipient: recipient,
					status: .delivered
				))
			} catch {
				outcomes.append(WorkspaceBroadcastOutcome(
					recipient: recipient,
					status: .failed(error.localizedDescription)
				))
			}
		}

		phase = .idle
		latestReport = WorkspaceBroadcastReport(plan: plan, outcomes: outcomes)
	}

	public func consumeReport() {
		latestReport = nil
	}
}
