import SwiftUI
import AppKit

/// SwiftUI wrapper around NSTextField with reliable tail truncation —
/// SwiftUI's Text + truncationMode(.tail) does not work consistently
/// inside a NavigationSplitView sidebar's List rows on macOS 14, even
/// with frame(maxWidth: .infinity) + minWidth: 0 + .clipped(). The
/// AppKit-native single-line text field does.
struct TruncatingLabel: NSViewRepresentable {
	let text: String
	var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
	var color: NSColor = .labelColor

	func makeNSView(context: Context) -> NSTextField {
		let tf = NSTextField(labelWithString: text)
		tf.usesSingleLineMode = true
		tf.lineBreakMode = .byTruncatingTail
		tf.cell?.truncatesLastVisibleLine = true
		tf.cell?.lineBreakMode = .byTruncatingTail
		tf.isBezeled = false
		tf.isEditable = false
		tf.isSelectable = false
		tf.drawsBackground = false
		tf.font = font
		tf.textColor = color
		// Tell AppKit it should compress horizontally when squeezed,
		// which is what makes the truncating cell actually truncate.
		tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
		return tf
	}

	func updateNSView(_ nsView: NSTextField, context: Context) {
		if nsView.stringValue != text { nsView.stringValue = text }
		nsView.font = font
		nsView.textColor = color
	}
}
