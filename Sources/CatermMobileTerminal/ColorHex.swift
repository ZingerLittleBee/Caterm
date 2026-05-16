#if canImport(UIKit)
import SwiftTerm
import UIKit

func parseHexRGB(_ hex: String) -> (r: Double, g: Double, b: Double)? {
	var s = hex.trimmingCharacters(in: .whitespaces)
	if s.hasPrefix("#") { s.removeFirst() }
	guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
	return (
		Double((v >> 16) & 0xff) / 255.0,
		Double((v >> 8) & 0xff) / 255.0,
		Double(v & 0xff) / 255.0
	)
}

extension UIColor {
	convenience init?(hex: String) {
		guard let c = parseHexRGB(hex) else { return nil }
		self.init(red: c.r, green: c.g, blue: c.b, alpha: 1)
	}
}

extension SwiftTerm.Color {
	convenience init?(hex: String) {
		guard let c = parseHexRGB(hex) else { return nil }
		self.init(
			red: UInt16(c.r * 65535),
			green: UInt16(c.g * 65535),
			blue: UInt16(c.b * 65535)
		)
	}
}
#endif
