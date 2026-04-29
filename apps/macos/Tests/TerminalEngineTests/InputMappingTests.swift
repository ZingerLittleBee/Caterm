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
}
