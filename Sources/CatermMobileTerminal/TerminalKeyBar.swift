import Foundation

/// Byte mapping + sticky-modifier state for the on-screen terminal keys.
///
/// `primaryRow` / `secondaryRow` stay as the compact accessory shown
/// alongside the native iOS keyboard. `grid` is the full Termius-style
/// custom keyboard (8 columns, 4 left + 4 right).
public struct TerminalKeyBar: Equatable {
	public enum Key: Hashable {
		case esc, ctrl, alt, tab, shiftTab
		case arrowUp, arrowDown, arrowLeft, arrowRight
		case home, end, pageUp, pageDown
		case insert, delete
		case paste
		/// Function keys F1…F12.
		case function(Int)
		/// One-shot Ctrl+<char> (e.g. `^C`), independent of sticky Ctrl.
		case control(String)
		/// One-shot Alt/Meta+<char> (e.g. `Alt-r`): emits ESC then the char.
		case altKey(String)
		/// Raw byte sequence for fixed combos like `^X^X`.
		case sequence([UInt8])
		/// A printable key; obeys sticky Ctrl then sticky Alt.
		case literal(String)
	}

	public private(set) var isCtrlActive = false
	public private(set) var isAltActive = false

	public let primaryRow: [Key] = [.esc, .ctrl, .tab, .arrowLeft, .arrowUp, .arrowDown, .arrowRight]
	public let secondaryRow: [Key] = [
		.literal("-"), .literal("|"), .literal("/"), .literal("~"),
		.home, .end, .pageUp, .pageDown,
	]

	/// Full custom keyboard, mirroring the Termius layout in the design.
	public let grid: [[Key]] = [
		[.esc, .tab, .ctrl, .alt, .literal("/"), .literal("|"), .literal("~"), .literal("-")],
		[.control("c"), .control("\\"), .control("s"), .control("z"), .shiftTab, .literal("?"), .literal("/"), .literal("\\")],
		[.home, .pageUp, .pageDown, .end, .literal("="), .literal(":"), .literal(";"), .literal("!")],
		[.literal("*"), .literal("$"), .literal("%"), .literal("^"), .literal("<"), .literal(">"), .literal("("), .literal(")")],
		[.literal("{"), .literal("}"), .literal("["), .literal("]"), .paste, .delete, .insert, .literal("@")],
		[.function(1), .function(2), .function(3), .function(4), .function(5), .function(6), .function(7), .function(8)],
		[.function(9), .function(10), .function(11), .function(12), .control("_"), .control("l"), .altKey("r"), .sequence([0x18, 0x18])],
		[.control("r"), .control("g"), .control("n"), .control("p"), .arrowLeft, .arrowUp, .arrowDown, .arrowRight],
	]

	public init() {}

	public mutating func toggleCtrl() { isCtrlActive.toggle() }
	public mutating func toggleAlt() { isAltActive.toggle() }

	public mutating func bytes(for key: Key) -> [UInt8] {
		switch key {
		case .ctrl:
			toggleCtrl()
			return []
		case .alt:
			toggleAlt()
			return []
		case .esc: return [0x1b]
		case .tab: return [0x09]
		case .shiftTab: return Array("\u{1b}[Z".utf8)
		case .arrowUp: return Array("\u{1b}[A".utf8)
		case .arrowDown: return Array("\u{1b}[B".utf8)
		case .arrowRight: return Array("\u{1b}[C".utf8)
		case .arrowLeft: return Array("\u{1b}[D".utf8)
		case .home: return Array("\u{1b}[H".utf8)
		case .end: return Array("\u{1b}[F".utf8)
		case .pageUp: return Array("\u{1b}[5~".utf8)
		case .pageDown: return Array("\u{1b}[6~".utf8)
		case .insert: return Array("\u{1b}[2~".utf8)
		case .delete: return Array("\u{1b}[3~".utf8)
		case .paste: return []
		case .function(let n): return Self.functionBytes(n)
		case .control(let s): return [Self.controlByte(for: s)]
		case .altKey(let s): return [0x1b] + Array(s.utf8)
		case .sequence(let bytes): return bytes
		case .literal(let s):
			if isCtrlActive {
				isCtrlActive = false
				return [Self.controlByte(for: s)]
			}
			if isAltActive {
				isAltActive = false
				return [0x1b] + Array(s.utf8)
			}
			return Array(s.utf8)
		}
	}

	static func functionBytes(_ n: Int) -> [UInt8] {
		switch n {
		case 1: return Array("\u{1b}OP".utf8)
		case 2: return Array("\u{1b}OQ".utf8)
		case 3: return Array("\u{1b}OR".utf8)
		case 4: return Array("\u{1b}OS".utf8)
		case 5: return Array("\u{1b}[15~".utf8)
		case 6: return Array("\u{1b}[17~".utf8)
		case 7: return Array("\u{1b}[18~".utf8)
		case 8: return Array("\u{1b}[19~".utf8)
		case 9: return Array("\u{1b}[20~".utf8)
		case 10: return Array("\u{1b}[21~".utf8)
		case 11: return Array("\u{1b}[23~".utf8)
		case 12: return Array("\u{1b}[24~".utf8)
		default: return []
		}
	}

	static func controlByte(for s: String) -> UInt8 {
		guard let scalar = s.uppercased().unicodeScalars.first else { return 0 }
		let v = scalar.value
		if v == 0x20 { return 0x00 }
		if (0x40...0x5f).contains(v) { return UInt8(v - 0x40) }
		if (0x61...0x7a).contains(v) { return UInt8(v - 0x60) }
		return UInt8(truncatingIfNeeded: v)
	}
}
