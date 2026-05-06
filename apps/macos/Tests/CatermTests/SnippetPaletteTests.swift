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
}

private final class MockDispatchTarget: SnippetDispatchTarget {
	var pasteCalls: [String] = []
	var runCalls: [String] = []
	func paste(_ text: String) { pasteCalls.append(text) }
	func run(_ text: String) { runCalls.append(text) }
}
