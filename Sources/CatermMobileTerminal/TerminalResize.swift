import CoreGraphics
import Foundation

public enum TerminalResize {
	public struct Grid: Equatable {
		public var cols: Int
		public var rows: Int
		public init(cols: Int, rows: Int) {
			self.cols = cols
			self.rows = rows
		}
	}

	public static func grid(
		pixelWidth: CGFloat,
		pixelHeight: CGFloat,
		cellWidth: CGFloat,
		cellHeight: CGFloat
	) -> Grid {
		guard cellWidth > 0, cellHeight > 0 else { return Grid(cols: 2, rows: 1) }
		let cols = max(2, Int((pixelWidth / cellWidth).rounded(.down)))
		let rows = max(1, Int((pixelHeight / cellHeight).rounded(.down)))
		return Grid(cols: cols, rows: rows)
	}

	public static func shouldSend(_ next: Grid, since last: Grid?) -> Bool {
		next != last
	}
}
