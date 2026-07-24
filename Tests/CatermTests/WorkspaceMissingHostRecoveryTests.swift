import Foundation
import SSHCommandBuilder
import WorkspaceCore
import XCTest
@testable import Caterm

@MainActor
final class WorkspaceMissingHostRecoveryTests: XCTestCase {
	func testCredentialFailureRollsBackNewHost() async throws {
		let host = makeHost()
		let workspace = Workspace.onePane(host: .saved(id: UUID()))
		var added = false
		var rolledBack: UUID?
		var replaced = false
		let transaction = WorkspaceMissingHostRecoveryTransaction(dependencies: .init(
			addHost: { _ in added = true },
			commitCredential: { _, _, _ in throw TestError.credential },
			replacePane: { _, _, workspace in replaced = true; return workspace },
			rollbackHost: { rolledBack = $0 }
		))

		await XCTAssertThrowsErrorAsync {
			_ = try await transaction.run(
				host: host,
				secret: nil,
				keyMaterial: nil,
				paneID: workspace.activePaneID,
				workspace: workspace
			)
		}

		XCTAssertTrue(added)
		XCTAssertFalse(replaced)
		XCTAssertEqual(rolledBack, host.id)
	}

	func testPaneReplacementFailureRollsBackCommittedHost() async throws {
		let host = makeHost()
		let workspace = Workspace.onePane(host: .saved(id: UUID()))
		var credentialCommitted = false
		var rolledBack: UUID?
		let transaction = WorkspaceMissingHostRecoveryTransaction(dependencies: .init(
			addHost: { _ in },
			commitCredential: { _, _, _ in credentialCommitted = true },
			replacePane: { _, _, _ in throw TestError.replacement },
			rollbackHost: { rolledBack = $0 }
		))

		await XCTAssertThrowsErrorAsync {
			_ = try await transaction.run(
				host: host,
				secret: nil,
				keyMaterial: nil,
				paneID: workspace.activePaneID,
				workspace: workspace
			)
		}

		XCTAssertTrue(credentialCommitted)
		XCTAssertEqual(rolledBack, host.id)
	}

	func testCancellationAfterAddRollsBackNewHost() async {
		let host = makeHost()
		let workspace = Workspace.onePane(host: .saved(id: UUID()))
		let credentialStarted = expectation(description: "credential commit started")
		var rolledBack: UUID?
		let transaction = WorkspaceMissingHostRecoveryTransaction(dependencies: .init(
			addHost: { _ in },
			commitCredential: { _, _, _ in
				credentialStarted.fulfill()
				try await Task.sleep(for: .seconds(10))
			},
			replacePane: { _, _, workspace in workspace },
			rollbackHost: { rolledBack = $0 }
		))
		let task = Task { @MainActor in
			try await transaction.run(
				host: host,
				secret: nil,
				keyMaterial: nil,
				paneID: workspace.activePaneID,
				workspace: workspace
			)
		}
		await fulfillment(of: [credentialStarted], timeout: 1)

		task.cancel()
		_ = try? await task.value

		XCTAssertEqual(rolledBack, host.id)
	}

	private func makeHost() -> SSHHost {
		SSHHost(
			name: "Recovery",
			hostname: "recovery.example",
			port: 22,
			username: "tester",
			credential: .agent
		)
	}
}

private enum TestError: Error {
	case credential
	case replacement
}

private func XCTAssertThrowsErrorAsync(
	_ expression: () async throws -> Void,
	file: StaticString = #filePath,
	line: UInt = #line
) async {
	do {
		try await expression()
		XCTFail("Expected error", file: file, line: line)
	} catch {}
}
