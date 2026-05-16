import Foundation

public struct TerminalKeyBar: Equatable {
	public enum Key: Hashable {
		case esc, ctrl, tab
		case arrowUp, arrowDown, arrowLeft, arrowRight
		case home, end, pageUp, pageDown
		case literal(String)
	}

	public private(set) var isCtrlActive = false
	public let primaryRow: [Key] = [.esc, .ctrl, .tab, .arrowLeft, .arrowUp, .arrowDown, .arrowRight]
	public let secondaryRow: [Key] = [
		.literal("-"), .literal("|"), .literal("/"), .literal("~"),
		.home, .end, .pageUp, .pageDown,
	]

	public init() {}

	public mutating func toggleCtrl() { isCtrlActive.toggle() }

	public mutating func bytes(for key: Key) -> [UInt8] {
		switch key {
		case .ctrl:
			toggleCtrl()
			return []
		case .esc: return [0x1b]
		case .tab: return [0x09]
		case .arrowUp: return Array("\u{1b}[A".utf8)
		case .arrowDown: return Array("\u{1b}[B".utf8)
		case .arrowRight: return Array("\u{1b}[C".utf8)
		case .arrowLeft: return Array("\u{1b}[D".utf8)
		case .home: return Array("\u{1b}[H".utf8)
		case .end: return Array("\u{1b}[F".utf8)
		case .pageUp: return Array("\u{1b}[5~".utf8)
		case .pageDown: return Array("\u{1b}[6~".utf8)
		case .literal(let s):
			guard isCtrlActive else { return Array(s.utf8) }
			isCtrlActive = false
			return [Self.controlByte(for: s)]
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
