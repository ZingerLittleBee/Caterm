import XCTest
import WorkspaceCore
@testable import Caterm

final class WorkspaceCommandTests: XCTestCase {
	func testSplitAndFocusCommandsUseWorkspaceOperations() throws {
		let workspace = Workspace.onePane(host: .saved(id: UUID()))
		guard case .update(let split) = try WorkspaceCommand.splitRight.applying(to: workspace)
		else {
			return XCTFail("Expected a Workspace update")
		}

		XCTAssertEqual(split.topology.paneCount, 2)
		XCTAssertNotEqual(split.activePaneID, workspace.activePaneID)

		guard case .update(let refocused) = try WorkspaceCommand.focusLeft.applying(to: split)
		else {
			return XCTFail("Expected a Workspace update")
		}
		XCTAssertEqual(refocused.activePaneID, workspace.activePaneID)
	}

	func testToggleAndCloseCommandsPreserveTypedOutcomes() throws {
		let workspace = Workspace.onePane(host: .saved(id: UUID()))

		guard case .update(let focused) = try WorkspaceCommand.toggleFocusMode.applying(to: workspace)
		else {
			return XCTFail("Expected a Workspace update")
		}
		XCTAssertEqual(focused.presentation, .focus)

		guard case .close(let result) = try WorkspaceCommand.closePane.applying(to: focused)
		else {
			return XCTFail("Expected a close outcome")
		}
		XCTAssertTrue(result.shouldCloseWindow)
		XCTAssertEqual(result.closedPaneID, workspace.activePaneID)
	}
}
