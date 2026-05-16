import FileTransferStore
@testable import CatermMobile
import XCTest

final class MobileFileBrowserModelTests: XCTestCase {
	func testFolderActivationAppendsChildPathUnderHomeRoot() {
		var model = MobileFileBrowserModel(path: "~")
		let entry = RemoteEntry(name: "logs", isDirectory: true, size: 0, mtime: nil, mode: 0o755)

		model.activate(entry)

		XCTAssertEqual(model.path, "~/logs")
	}

	func testFolderActivationAppendsChildPathUnderFilesystemRoot() {
		var model = MobileFileBrowserModel(path: "/")
		let entry = RemoteEntry(name: "var", isDirectory: true, size: 0, mtime: nil, mode: 0o755)

		model.activate(entry)

		XCTAssertEqual(model.path, "/var")
	}

	func testGoUpPreservesHomeAndFilesystemRoots() {
		var home = MobileFileBrowserModel(path: "~")
		var root = MobileFileBrowserModel(path: "/")

		home.goUp()
		root.goUp()

		XCTAssertEqual(home.path, "~")
		XCTAssertEqual(root.path, "/")
	}

	func testGoUpMovesToParentPath() {
		var homeChild = MobileFileBrowserModel(path: "~/logs/archive")
		var rootChild = MobileFileBrowserModel(path: "/var/log")

		homeChild.goUp()
		rootChild.goUp()

		XCTAssertEqual(homeChild.path, "~/logs")
		XCTAssertEqual(rootChild.path, "/var")
	}

	func testFileActivationStagesDownloadSheet() {
		var model = MobileFileBrowserModel(path: "~/logs")
		let entry = RemoteEntry(name: "app.log", isDirectory: false, size: 123, mtime: nil, mode: 0o644)

		model.activate(entry)

		XCTAssertEqual(model.presentation, .download(path: "~/logs/app.log"))
	}

	func testDeleteAndRenameStageExplicitPresentationState() {
		var model = MobileFileBrowserModel(path: "/var")
		let entry = RemoteEntry(name: "log", isDirectory: true, size: 0, mtime: nil, mode: 0o755)

		model.requestDelete(entry)
		XCTAssertEqual(model.presentation, .confirmDelete(path: "/var/log", isDirectory: true))

		model.requestRename(entry)
		XCTAssertEqual(model.presentation, .rename(path: "/var/log", currentName: "log"))
	}
}
