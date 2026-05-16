import XCTest
@testable import Caterm

final class MainWindowToolbarTests: XCTestCase {
	func testPrimaryToolbarActionsKeepSnippetsBesideFiles() {
		XCTAssertEqual(
			MainWindowToolbarAction.allCases.map(\.systemImage),
			["text.cursor", "folder"]
		)
		XCTAssertEqual(
			MainWindowToolbarAction.allCases.map(\.help),
			["Snippets (⌘⇧P)", "Toggle Files Drawer (⌘⇧F)"]
		)
	}

	func testSnippetPaletteFrameIsCenteredInWindowContent() {
		let container = CGSize(width: 1_154, height: 700)

		let frame = MainWindowSnippetPalettePlacement.frame(in: container)

		XCTAssertEqual(frame.midX, container.width / 2, accuracy: 0.001)
		XCTAssertEqual(frame.midY, container.height / 2, accuracy: 0.001)
	}
}
