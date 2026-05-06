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
}
