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

	func testGridIsEightColumnsAndCoversTermiusKeys() {
		let bar = TerminalKeyBar()
		XCTAssertEqual(bar.grid.count, 8)
		for row in bar.grid { XCTAssertEqual(row.count, 8) }
		let flat = bar.grid.flatMap { $0 }
		XCTAssertTrue(flat.contains(.alt))
		XCTAssertTrue(flat.contains(.shiftTab))
		XCTAssertTrue(flat.contains(.function(1)))
		XCTAssertTrue(flat.contains(.function(12)))
		XCTAssertTrue(flat.contains(.control("c")))
		XCTAssertTrue(flat.contains(.paste))
		XCTAssertTrue(flat.contains(.delete))
		XCTAssertTrue(flat.contains(.insert))
	}

	func testFunctionKeyBytes() {
		var bar = TerminalKeyBar()
		XCTAssertEqual(bar.bytes(for: .function(1)), Array("\u{1b}OP".utf8))
		XCTAssertEqual(bar.bytes(for: .function(4)), Array("\u{1b}OS".utf8))
		XCTAssertEqual(bar.bytes(for: .function(5)), Array("\u{1b}[15~".utf8))
		XCTAssertEqual(bar.bytes(for: .function(12)), Array("\u{1b}[24~".utf8))
	}

	func testNamedControlAndSequenceAndShiftTab() {
		var bar = TerminalKeyBar()
		XCTAssertEqual(bar.bytes(for: .control("c")), [0x03])
		XCTAssertEqual(bar.bytes(for: .control("\\")), [0x1c])
		XCTAssertEqual(bar.bytes(for: .control("_")), [0x1f])
		XCTAssertEqual(bar.bytes(for: .sequence([0x18, 0x18])), [0x18, 0x18])
		XCTAssertEqual(bar.bytes(for: .shiftTab), Array("\u{1b}[Z".utf8))
		XCTAssertEqual(bar.bytes(for: .insert), Array("\u{1b}[2~".utf8))
		XCTAssertEqual(bar.bytes(for: .delete), Array("\u{1b}[3~".utf8))
		XCTAssertEqual(bar.bytes(for: .paste), [])
	}

	func testStickyAltAppliesEscPrefixThenClears() {
		var bar = TerminalKeyBar()
		XCTAssertFalse(bar.isAltActive)
		bar.toggleAlt()
		XCTAssertTrue(bar.isAltActive)
		XCTAssertEqual(bar.bytes(for: .literal("f")), [0x1b] + Array("f".utf8))
		XCTAssertFalse(bar.isAltActive)
		XCTAssertEqual(bar.bytes(for: .literal("f")), Array("f".utf8))
	}

	func testAltKeyOneShot() {
		var bar = TerminalKeyBar()
		XCTAssertEqual(bar.bytes(for: .altKey("r")), [0x1b] + Array("r".utf8))
	}
}
