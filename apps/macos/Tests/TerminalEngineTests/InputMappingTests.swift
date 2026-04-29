import AppKit
import GhosttyKit
import XCTest

@testable import TerminalEngine

final class InputMappingTests: XCTestCase {
	func testGhosttyMods_empty() {
		XCTAssertEqual(ghosttyMods(NSEvent.ModifierFlags()).rawValue, 0)
	}

	func testGhosttyMods_singleModifier() {
		XCTAssertEqual(ghosttyMods([.shift]).rawValue, GHOSTTY_MODS_SHIFT.rawValue)
		XCTAssertEqual(ghosttyMods([.control]).rawValue, GHOSTTY_MODS_CTRL.rawValue)
		XCTAssertEqual(ghosttyMods([.option]).rawValue, GHOSTTY_MODS_ALT.rawValue)
		XCTAssertEqual(ghosttyMods([.command]).rawValue, GHOSTTY_MODS_SUPER.rawValue)
		XCTAssertEqual(ghosttyMods([.capsLock]).rawValue, GHOSTTY_MODS_CAPS.rawValue)
	}

	func testGhosttyMods_combined() {
		let raw = ghosttyMods([.shift, .command]).rawValue
		XCTAssertEqual(raw, GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_SUPER.rawValue)
	}

	// MARK: - ghosttyMouseButton

	func testGhosttyMouseButton_allCases() {
		XCTAssertEqual(ghosttyMouseButton(buttonNumber: 0), GHOSTTY_MOUSE_LEFT)
		XCTAssertEqual(ghosttyMouseButton(buttonNumber: 1), GHOSTTY_MOUSE_RIGHT)
		XCTAssertEqual(ghosttyMouseButton(buttonNumber: 2), GHOSTTY_MOUSE_MIDDLE)
	}

	func testGhosttyMouseButton_unknownButtons_clampToUnknown() {
		XCTAssertEqual(ghosttyMouseButton(buttonNumber: 99), GHOSTTY_MOUSE_UNKNOWN)
		XCTAssertEqual(ghosttyMouseButton(buttonNumber: -1), GHOSTTY_MOUSE_UNKNOWN)
	}

	// MARK: - scrollMods

	func testScrollMods_precise() {
		XCTAssertNotEqual(scrollMods(precise: true, momentum: []) & 0x1, 0)
	}

	func testScrollMods_imprecise() {
		XCTAssertEqual(scrollMods(precise: false, momentum: []) & 0x1, 0)
	}

	func testScrollMods_momentumBeganShiftsIntoBits1to3() {
		// Bit 0 is "precise"; bits 1..3 encode momentum phase. .began == 1.
		let bits = scrollMods(precise: false, momentum: .began)
		XCTAssertEqual(bits & 0x1, 0, "precise bit should be unset")
		XCTAssertEqual((bits >> 1) & 0x7, 1, "momentum phase bits should encode 1 for .began")
	}

	// Each AppKit `NSEvent.Phase` flag must map to the matching numeric value
	// of `ghostty_input_mouse_momentum_e` in ghostty.h:107-115. If these
	// drift, libghostty will silently misinterpret the phase (e.g., decode
	// CHANGED as STATIONARY). See I-1 in the v1.5 review.

	func testScrollMods_momentumNone() {
		let bits = scrollMods(precise: false, momentum: [])
		XCTAssertEqual((bits >> 1) & 0x7, 0)
	}

	func testScrollMods_momentumStationary() {
		let bits = scrollMods(precise: false, momentum: .stationary)
		XCTAssertEqual((bits >> 1) & 0x7, 2)
	}

	func testScrollMods_momentumChanged() {
		let bits = scrollMods(precise: false, momentum: .changed)
		XCTAssertEqual((bits >> 1) & 0x7, 3)
	}

	func testScrollMods_momentumEnded() {
		let bits = scrollMods(precise: false, momentum: .ended)
		XCTAssertEqual((bits >> 1) & 0x7, 4)
	}

	func testScrollMods_momentumCancelled() {
		let bits = scrollMods(precise: false, momentum: .cancelled)
		XCTAssertEqual((bits >> 1) & 0x7, 5)
	}

	func testScrollMods_momentumMayBegin() {
		let bits = scrollMods(precise: false, momentum: .mayBegin)
		XCTAssertEqual((bits >> 1) & 0x7, 6)
	}
}
