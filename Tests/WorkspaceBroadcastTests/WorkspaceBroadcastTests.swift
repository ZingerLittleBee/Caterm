import XCTest
import WorkspaceCore
@testable import WorkspaceBroadcast

@MainActor
final class WorkspaceBroadcastTests: XCTestCase {
	func testPlanRejectsEmptyTextAndFewerThanTwoRecipients() throws {
		let workspaceID = WorkspaceID()
		let first = recipient(workspaceID: workspaceID)
		let second = recipient(workspaceID: workspaceID)

		XCTAssertThrowsError(
			try WorkspaceBroadcastPlan(
				workspaceID: workspaceID,
				source: .command("   \n"),
				recipients: [first, second]
			)
		) { error in
			XCTAssertEqual(error as? WorkspaceBroadcastError, .emptyCommand)
		}
		XCTAssertThrowsError(
			try WorkspaceBroadcastPlan(
				workspaceID: workspaceID,
				source: .command("printf safe"),
				recipients: [first]
			)
		) { error in
			XCTAssertEqual(error as? WorkspaceBroadcastError, .requiresTwoRecipients)
		}
	}

	func testPlanRejectsRecipientFromAnotherWindow() throws {
		let workspaceID = WorkspaceID()
		let first = recipient(workspaceID: workspaceID)
		let foreign = recipient(workspaceID: WorkspaceID())

		XCTAssertThrowsError(
			try WorkspaceBroadcastPlan(
				workspaceID: workspaceID,
				source: .command("printf safe"),
				recipients: [first, foreign]
			)
		) { error in
			XCTAssertEqual(error as? WorkspaceBroadcastError, .crossWorkspaceRecipient)
		}
	}

	func testDeliveryUsesFrozenRecipientsAndExactTextOnce() async throws {
		let workspaceID = WorkspaceID()
		let first = recipient(workspaceID: workspaceID)
		let second = recipient(workspaceID: workspaceID)
		let addedAfterArming = recipient(workspaceID: workspaceID)
		let exactText = "printf 'safe value' && uname -s"
		let plan = try WorkspaceBroadcastPlan(
			workspaceID: workspaceID,
			source: .command(exactText),
			recipients: [first, second]
		)
		let session = WorkspaceBroadcastSession()
		session.arm(plan)
		var deliveries: [(PaneID, String)] = []

		await session.deliver(
			eligibility: { recipient in
				[first.id, second.id, addedAfterArming.id].contains(recipient.id)
					? .eligible : .missing
			},
			send: { recipient, text in
				deliveries.append((recipient.id, text))
			}
		)

		XCTAssertEqual(deliveries.map(\.0), [first.id, second.id])
		XCTAssertEqual(deliveries.map(\.1), [exactText, exactText])
		XCTAssertEqual(session.latestReport?.outcomes.map(\.status), [.delivered, .delivered])
	}

	func testExactReviewedCommandRunsInTwoHarmlessLocalTerminals() async throws {
		let workspaceID = WorkspaceID()
		let first = recipient(workspaceID: workspaceID)
		let second = recipient(workspaceID: workspaceID)
		let exactText = "printf 'broadcast-safe\\n'"
		let plan = try WorkspaceBroadcastPlan(
			workspaceID: workspaceID,
			source: .command(exactText),
			recipients: [first, second]
		)
		let firstTerminal = try HarmlessLocalTerminal()
		let secondTerminal = try HarmlessLocalTerminal()
		let terminals = [
			first.id: firstTerminal,
			second.id: secondTerminal,
		]
		let session = WorkspaceBroadcastSession()
		session.arm(plan)
		var deliveredText: [String] = []

		await session.deliver(
			eligibility: { _ in .eligible },
			send: { recipient, text in
				deliveredText.append(text)
				guard let terminal = terminals[recipient.id] else {
					throw LocalTerminalError.missingRecipient
				}
				try terminal.send(text)
			}
		)

		XCTAssertEqual(deliveredText, [exactText, exactText])
		XCTAssertEqual(try firstTerminal.finish(), "broadcast-safe\n")
		XCTAssertEqual(try secondTerminal.finish(), "broadcast-safe\n")
	}

	func testReplacedSurfaceIsSkippedAndNeverReplayed() async throws {
		let workspaceID = WorkspaceID()
		let first = recipient(workspaceID: workspaceID)
		let second = recipient(workspaceID: workspaceID)
		let plan = try WorkspaceBroadcastPlan(
			workspaceID: workspaceID,
			source: .command("printf safe"),
			recipients: [first, second]
		)
		let session = WorkspaceBroadcastSession()
		session.arm(plan)
		var deliveries: [PaneID] = []

		await session.deliver(
			eligibility: { $0.id == first.id ? .eligible : .surfaceReplaced },
			send: { recipient, _ in deliveries.append(recipient.id) }
		)

		XCTAssertEqual(deliveries, [first.id])
		XCTAssertEqual(
			session.latestReport?.outcomes.map(\.status),
			[.delivered, .skipped(.surfaceReplaced)]
		)
		XCTAssertFalse(session.canDeliver)

		await session.deliver(
			eligibility: { _ in .eligible },
			send: { recipient, _ in deliveries.append(recipient.id) }
		)
		XCTAssertEqual(deliveries, [first.id])
	}

	func testPartialFailureRemainsPerRecipient() async throws {
		let workspaceID = WorkspaceID()
		let first = recipient(workspaceID: workspaceID)
		let second = recipient(workspaceID: workspaceID)
		let third = recipient(workspaceID: workspaceID)
		let plan = try WorkspaceBroadcastPlan(
			workspaceID: workspaceID,
			source: .snippet(id: UUID(), name: "Safe", text: "date"),
			recipients: [first, second, third]
		)
		let session = WorkspaceBroadcastSession()
		session.arm(plan)

		await session.deliver(
			eligibility: { $0.id == second.id ? .disconnected : .eligible },
			send: { recipient, _ in
				if recipient.id == third.id { throw TestError.deliveryFailed }
			}
		)

		XCTAssertEqual(
			session.latestReport?.outcomes.map(\.status),
			[.delivered, .skipped(.disconnected), .failed("Delivery failed safely.")]
		)
	}

	func testArmedSessionAutoDisarmsBelowTwoEligibleRecipients() throws {
		let workspaceID = WorkspaceID()
		let first = recipient(workspaceID: workspaceID)
		let second = recipient(workspaceID: workspaceID)
		let plan = try WorkspaceBroadcastPlan(
			workspaceID: workspaceID,
			source: .command("date"),
			recipients: [first, second]
		)
		let session = WorkspaceBroadcastSession()
		session.arm(plan)

		let result = session.reconcileEligibility {
			$0.id == first.id ? .eligible : .disconnected
		}

		XCTAssertEqual(result, .disarmed)
		XCTAssertEqual(session.phase, .idle)
	}

	func testDeliveryStopsWhenDisconnectionsLeaveOneEligibleRecipient() async throws {
		let workspaceID = WorkspaceID()
		let first = recipient(workspaceID: workspaceID)
		let second = recipient(workspaceID: workspaceID)
		let third = recipient(workspaceID: workspaceID)
		let plan = try WorkspaceBroadcastPlan(
			workspaceID: workspaceID,
			source: .command("date"),
			recipients: [first, second, third]
		)
		let session = WorkspaceBroadcastSession()
		session.arm(plan)
		var disconnectedPaneIDs: Set<PaneID> = []
		var reconciliation = WorkspaceBroadcastReconciliation.unchanged

		await session.deliver(
			eligibility: { recipient in
				disconnectedPaneIDs.contains(recipient.id) ? .disconnected : .eligible
			},
			send: { recipient, _ in
				guard recipient.id == first.id else { return }
				disconnectedPaneIDs = [first.id, second.id]
				reconciliation = session.reconcileEligibility { candidate in
					disconnectedPaneIDs.contains(candidate.id) ? .disconnected : .eligible
				}
			}
		)

		XCTAssertEqual(reconciliation, .stoppingDelivery)
		XCTAssertEqual(
			session.latestReport?.outcomes.map(\.status),
			[.delivered, .skipped(.disconnected), .skipped(.stopped)]
		)
	}

	func testUnrelatedReconciliationDoesNotStopHealthyRecipients() async throws {
		let workspaceID = WorkspaceID()
		let first = recipient(workspaceID: workspaceID)
		let second = recipient(workspaceID: workspaceID)
		let third = recipient(workspaceID: workspaceID)
		let plan = try WorkspaceBroadcastPlan(
			workspaceID: workspaceID,
			source: .command("date"),
			recipients: [first, second, third]
		)
		let session = WorkspaceBroadcastSession()
		session.arm(plan)
		var deliveries: [PaneID] = []
		var reconciliation = WorkspaceBroadcastReconciliation.unchanged

		await session.deliver(
			eligibility: { _ in .eligible },
			send: { recipient, _ in
				deliveries.append(recipient.id)
				if recipient.id == first.id {
					reconciliation = session.reconcileEligibility { _ in .eligible }
				}
			}
		)

		XCTAssertEqual(reconciliation, .unchanged)
		XCTAssertEqual(deliveries, [first.id, second.id, third.id])
		XCTAssertEqual(
			session.latestReport?.outcomes.map(\.status),
			[.delivered, .delivered, .delivered]
		)
	}

	func testStopDuringDeliverySkipsRemainingRecipients() async throws {
		let workspaceID = WorkspaceID()
		let first = recipient(workspaceID: workspaceID)
		let second = recipient(workspaceID: workspaceID)
		let third = recipient(workspaceID: workspaceID)
		let plan = try WorkspaceBroadcastPlan(
			workspaceID: workspaceID,
			source: .command("date"),
			recipients: [first, second, third]
		)
		let session = WorkspaceBroadcastSession()
		session.arm(plan)

		await session.deliver(
			eligibility: { _ in .eligible },
			send: { recipient, _ in
				if recipient.id == first.id { session.stop() }
			}
		)

		XCTAssertEqual(
			session.latestReport?.outcomes.map(\.status),
			[.delivered, .skipped(.stopped), .skipped(.stopped)]
		)
	}

	private func recipient(workspaceID: WorkspaceID) -> WorkspaceBroadcastRecipient {
		WorkspaceBroadcastRecipient(
			workspaceID: workspaceID,
			paneID: PaneID(),
			sessionID: UUID(),
			surfaceLeaseID: UUID(),
			paneLabel: "Pane",
			hostName: "Local",
			address: "tester@127.0.0.1:22"
		)
	}
}

private enum TestError: Error, LocalizedError {
	case deliveryFailed

	var errorDescription: String? { "Delivery failed safely." }
}

private final class HarmlessLocalTerminal {
	private let process: Process
	private let input: Pipe
	private let output: Pipe
	private var finished = false

	init() throws {
		process = Process()
		input = Pipe()
		output = Pipe()
		process.executableURL = URL(fileURLWithPath: "/bin/sh")
		process.standardInput = input
		process.standardOutput = output
		process.standardError = output
		try process.run()
	}

	func send(_ command: String) throws {
		guard let data = "\(command)\n".data(using: .utf8) else {
			throw LocalTerminalError.invalidUTF8
		}
		try input.fileHandleForWriting.write(contentsOf: data)
	}

	func finish() throws -> String {
		guard !finished else { throw LocalTerminalError.alreadyFinished }
		finished = true
		try send("exit")
		try input.fileHandleForWriting.close()
		process.waitUntilExit()
		let data = try output.fileHandleForReading.readToEnd() ?? Data()
		guard let text = String(data: data, encoding: .utf8) else {
			throw LocalTerminalError.invalidUTF8
		}
		return text
	}

	deinit {
		if process.isRunning { process.terminate() }
	}
}

private enum LocalTerminalError: Error {
	case invalidUTF8
	case alreadyFinished
	case missingRecipient
}
