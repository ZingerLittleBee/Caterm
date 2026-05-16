@testable import CatermMobileTerminal
import XCTest

final class TerminalResizeTests: XCTestCase {
	func testComputesColsRowsFromCellSize() {
		let r = TerminalResize.grid(
			pixelWidth: 390, pixelHeight: 600, cellWidth: 7.5, cellHeight: 15)
		XCTAssertEqual(r.cols, 52)
		XCTAssertEqual(r.rows, 40)
	}

	func testClampsToMinimums() {
		let r = TerminalResize.grid(
			pixelWidth: 1, pixelHeight: 1, cellWidth: 7.5, cellHeight: 15)
		XCTAssertEqual(r.cols, 2)
		XCTAssertEqual(r.rows, 1)
	}

	func testSuppressesNoOpChange() {
		var last: TerminalResize.Grid? = TerminalResize.Grid(cols: 80, rows: 24)
		let same = TerminalResize.Grid(cols: 80, rows: 24)
		XCTAssertFalse(TerminalResize.shouldSend(same, since: last))
		let changed = TerminalResize.Grid(cols: 81, rows: 24)
		XCTAssertTrue(TerminalResize.shouldSend(changed, since: last))
		last = nil
		XCTAssertTrue(TerminalResize.shouldSend(same, since: last))
	}
}
