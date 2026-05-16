import SnippetSyncClient
@testable import CatermMobile
import XCTest

final class MobileSnippetActionsTests: XCTestCase {
	func testCopyIsAvailableForNonEmptySnippetContent() {
		let snippet = makeSnippet(content: "uptime")

		XCTAssertTrue(MobileSnippetActions.canCopy(snippet))
	}

	func testCopyIsUnavailableForBlankSnippetContent() {
		let snippet = makeSnippet(content: " \n\t ")

		XCTAssertFalse(MobileSnippetActions.canCopy(snippet))
	}

	func testRunWithoutTargetRoutesToTerminalPlaceholder() {
		let snippet = makeSnippet(content: "uptime")

		let route = MobileSnippetActions.runRoute(for: snippet, targetHostId: nil)

		XCTAssertEqual(route, .terminalPlaceholder(snippet.id))
	}

	func testRunWithTargetRoutesToHostTerminal() {
		let snippet = makeSnippet(content: "uptime")
		let hostId = UUID()

		let route = MobileSnippetActions.runRoute(for: snippet, targetHostId: hostId)

		XCTAssertEqual(route, .hostTerminal(hostId: hostId, snippetId: snippet.id))
	}

	private func makeSnippet(content: String) -> Snippet {
		Snippet(
			id: UUID(),
			name: "Status",
			content: content,
			createdAt: Date(timeIntervalSince1970: 100),
			updatedAt: Date(timeIntervalSince1970: 200)
		)
	}
}
