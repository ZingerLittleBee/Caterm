import XCTest
import SnippetSyncClient
import SnippetStore
@testable import Caterm

@MainActor
final class SnippetPaletteViewModelTests: XCTestCase {
	private func makeStore() throws -> SnippetStore {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("palette-vm-\(UUID())")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let store = SnippetStore(directory: dir)
		try store.load()
		return store
	}

	func test_filter_matchesNameAndContent() throws {
		let store = try makeStore()
		try store.upsert(Snippet(id: UUID(), name: "ls", content: "ls -la",
		                        createdAt: .now, updatedAt: .now))
		try store.upsert(Snippet(id: UUID(), name: "docker", content: "docker ps",
		                        createdAt: .now, updatedAt: .now))
		let vm = SnippetPaletteViewModel(store: store, capturedSurface: nil)
		vm.query = "doc"
		XCTAssertEqual(vm.results.map(\.name), ["docker"])
	}

	func test_dispatchEnabled_falseWhenNoSurface() throws {
		let store = try makeStore()
		try store.upsert(Snippet(id: UUID(), name: "n", content: "c",
		                        createdAt: .now, updatedAt: .now))
		let vm = SnippetPaletteViewModel(store: store, capturedSurface: nil)
		XCTAssertFalse(vm.canDispatch)
	}

	func test_paste_callsDispatchTarget() throws {
		let store = try makeStore()
		let s = Snippet(id: UUID(), name: "n", content: "echo hi",
		                createdAt: .now, updatedAt: .now)
		try store.upsert(s)
		let mock = MockDispatchTarget()
		let vm = SnippetPaletteViewModel(store: store, capturedSurface: mock)
		vm.paste(s)
		XCTAssertEqual(mock.pasteCalls, ["echo hi"])
	}

	func test_run_callsDispatchTarget() throws {
		let store = try makeStore()
		let s = Snippet(id: UUID(), name: "n", content: "echo hi",
		                createdAt: .now, updatedAt: .now)
		try store.upsert(s)
		let mock = MockDispatchTarget()
		let vm = SnippetPaletteViewModel(store: store, capturedSurface: mock)
		vm.run(s)
		XCTAssertEqual(mock.runCalls, ["echo hi"])
	}

	// MARK: - Keyboard navigation

	/// Build a VM with three snippets ordered c (newest) > b > a (oldest)
	/// in the `results` array, matching the palette's `updatedAt` desc sort.
	private func makeNavigationVM() throws -> (SnippetPaletteViewModel, [UUID]) {
		let store = try makeStore()
		let now = Date()
		let ids = [UUID(), UUID(), UUID()] // a, b, c
		// Use a neutral content string so `search("c")` matches name only,
		// not all three via shared content substrings.
		try store.upsert(Snippet(id: ids[0], name: "alpha", content: "X",
		                         createdAt: now, updatedAt: now))
		try store.upsert(Snippet(id: ids[1], name: "beta", content: "X",
		                         createdAt: now, updatedAt: now.addingTimeInterval(1)))
		try store.upsert(Snippet(id: ids[2], name: "gamma", content: "X",
		                         createdAt: now, updatedAt: now.addingTimeInterval(2)))
		let vm = SnippetPaletteViewModel(store: store, capturedSurface: nil)
		return (vm, ids) // ids = [a, b, c]; results order = [c, b, a]
	}

	func test_moveDown_fromNil_selectsFirstResult() throws {
		let (vm, ids) = try makeNavigationVM()
		XCTAssertNil(vm.selectedID)
		vm.moveSelectionDown()
		XCTAssertEqual(vm.selectedID, ids[2]) // c — newest
	}

	func test_moveDown_advancesByOne() throws {
		let (vm, ids) = try makeNavigationVM()
		vm.selectedID = ids[2] // c
		vm.moveSelectionDown()
		XCTAssertEqual(vm.selectedID, ids[1]) // b
		vm.moveSelectionDown()
		XCTAssertEqual(vm.selectedID, ids[0]) // a
	}

	func test_moveDown_clampsAtEnd() throws {
		let (vm, ids) = try makeNavigationVM()
		vm.selectedID = ids[0] // a — last
		vm.moveSelectionDown()
		XCTAssertEqual(vm.selectedID, ids[0])
	}

	func test_moveUp_fromNil_selectsFirstResult() throws {
		let (vm, ids) = try makeNavigationVM()
		vm.moveSelectionUp()
		XCTAssertEqual(vm.selectedID, ids[2]) // c — same fallback as down
	}

	func test_moveUp_advancesByOne() throws {
		let (vm, ids) = try makeNavigationVM()
		vm.selectedID = ids[0] // a
		vm.moveSelectionUp()
		XCTAssertEqual(vm.selectedID, ids[1]) // b
		vm.moveSelectionUp()
		XCTAssertEqual(vm.selectedID, ids[2]) // c
	}

	func test_moveUp_clampsAtStart() throws {
		let (vm, ids) = try makeNavigationVM()
		vm.selectedID = ids[2] // c — first
		vm.moveSelectionUp()
		XCTAssertEqual(vm.selectedID, ids[2])
	}

	func test_moveSelection_emptyResults_noOp() throws {
		let store = try makeStore()
		let vm = SnippetPaletteViewModel(store: store, capturedSurface: nil)
		vm.moveSelectionDown()
		XCTAssertNil(vm.selectedID)
		vm.moveSelectionUp()
		XCTAssertNil(vm.selectedID)
	}

	func test_currentSelection_fallsBackToFirst_whenSelectedIDFilteredOut() throws {
		let (vm, ids) = try makeNavigationVM()
		vm.selectedID = ids[0] // "alpha"
		vm.query = "gam" // filters to only "gamma"
		// Selected id no longer in results → fall back to first match.
		XCTAssertEqual(vm.currentSelection?.id, ids[2])
	}

	func test_currentSelection_returnsSelectedSnippet() throws {
		let (vm, ids) = try makeNavigationVM()
		vm.selectedID = ids[1]
		XCTAssertEqual(vm.currentSelection?.id, ids[1])
	}
}

private final class MockDispatchTarget: SnippetDispatchTarget {
	var pasteCalls: [String] = []
	var runCalls: [String] = []
	func paste(_ text: String) { pasteCalls.append(text) }
	func run(_ text: String) { runCalls.append(text) }
}
