@testable import CatermMobileTerminal
import XCTest

final class TerminalKeyBarTests: XCTestCase {
	func testPlainKeysMapToBytes() {
		var bar = TerminalKeyBar()
		XCTAssertEqual(bar.bytes(for: .esc), [0x1b])
		XCTAssertEqual(bar.bytes(for: .tab), [0x09])
		XCTAssertEqual(bar.bytes(for: .arrowUp), Array("\u{1b}[A".utf8))
		XCTAssertEqual(bar.bytes(for: .arrowDown), Array("\u{1b}[B".utf8))
		XCTAssertEqual(bar.bytes(for: .arrowRight), Array("\u{1b}[C".utf8))
		XCTAssertEqual(bar.bytes(for: .arrowLeft), Array("\u{1b}[D".utf8))
		XCTAssertEqual(bar.bytes(for: .home), Array("\u{1b}[H".utf8))
		XCTAssertEqual(bar.bytes(for: .end), Array("\u{1b}[F".utf8))
		XCTAssertEqual(bar.bytes(for: .pageUp), Array("\u{1b}[5~".utf8))
		XCTAssertEqual(bar.bytes(for: .pageDown), Array("\u{1b}[6~".utf8))
		XCTAssertEqual(bar.bytes(for: .literal("|")), Array("|".utf8))
	}

	func testStickyCtrlAppliesToNextLetterThenClears() {
		var bar = TerminalKeyBar()
		XCTAssertFalse(bar.isCtrlActive)
		bar.toggleCtrl()
		XCTAssertTrue(bar.isCtrlActive)
		XCTAssertEqual(bar.bytes(for: .literal("c")), [0x03])
		XCTAssertFalse(bar.isCtrlActive)
		XCTAssertEqual(bar.bytes(for: .literal("c")), Array("c".utf8))
	}

	func testCtrlOnNonLetterPassesThrough() {
		var bar = TerminalKeyBar()
		bar.toggleCtrl()
		XCTAssertEqual(bar.bytes(for: .literal("[")), [0x1b])
		bar.toggleCtrl()
		XCTAssertEqual(bar.bytes(for: .literal(" ")), [0x00])
	}

	func testDefaultLayoutHasTermiusEssentials() {
		let bar = TerminalKeyBar()
		XCTAssertEqual(bar.primaryRow, [.esc, .ctrl, .tab, .arrowLeft, .arrowUp, .arrowDown, .arrowRight])
		XCTAssertTrue(bar.secondaryRow.contains(.literal("|")))
		XCTAssertTrue(bar.secondaryRow.contains(.home))
		XCTAssertTrue(bar.secondaryRow.contains(.pageUp))
	}
}
