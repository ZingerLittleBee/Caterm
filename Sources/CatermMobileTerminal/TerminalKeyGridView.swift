#if canImport(UIKit)
import SwiftUI

/// Full Termius-style 8-column custom keyboard.
struct TerminalKeyGridView: View {
	@ObservedObject var model: TerminalScreenModel

	var body: some View {
		VStack(spacing: 5) {
			ForEach(Array(model.keyBar.grid.enumerated()), id: \.offset) { _, row in
				HStack(spacing: 5) {
					ForEach(Array(row.enumerated()), id: \.offset) { _, key in
						keyButton(key)
					}
				}
			}
		}
		.padding(.horizontal, 6)
		.padding(.vertical, 6)
		.frame(maxWidth: .infinity)
		.background(Color(.secondarySystemBackground))
	}

	@ViewBuilder private func keyButton(_ key: TerminalKeyBar.Key) -> some View {
		Button {
			model.tapKey(key)
		} label: {
			Text(TerminalKeyLabel.label(for: key))
				.font(.system(.footnote, design: .monospaced))
				.lineLimit(1)
				.minimumScaleFactor(0.6)
				.frame(maxWidth: .infinity, minHeight: 34)
				.background(
					highlighted(key) ? Color.accentColor.opacity(0.5) : Color(.tertiarySystemBackground),
					in: RoundedRectangle(cornerRadius: 7))
		}
		.buttonStyle(.plain)
		.accessibilityLabel(TerminalKeyLabel.label(for: key))
	}

	private func highlighted(_ key: TerminalKeyBar.Key) -> Bool {
		(key == .ctrl && model.keyBar.isCtrlActive)
			|| (key == .alt && model.keyBar.isAltActive)
	}
}

/// Compact quick-access row shown above the native iOS keyboard.
struct TerminalAccessoryRow: View {
	@ObservedObject var model: TerminalScreenModel

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 6) {
				ForEach(Array(model.keyBar.primaryRow.enumerated()), id: \.offset) { _, key in
					chip(key)
				}
				Divider().frame(height: 22)
				ForEach(Array(model.keyBar.secondaryRow.enumerated()), id: \.offset) { _, key in
					chip(key)
				}
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 5)
		}
		.background(.bar)
	}

	@ViewBuilder private func chip(_ key: TerminalKeyBar.Key) -> some View {
		Button {
			model.tapKey(key)
		} label: {
			Text(TerminalKeyLabel.label(for: key))
				.font(.system(.callout, design: .monospaced))
				.frame(minWidth: 32, minHeight: 28)
				.background(
					(key == .ctrl && model.keyBar.isCtrlActive)
						? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15),
					in: RoundedRectangle(cornerRadius: 6))
		}
		.buttonStyle(.plain)
		.accessibilityLabel(TerminalKeyLabel.label(for: key))
	}
}

enum TerminalKeyLabel {
	static func label(for key: TerminalKeyBar.Key) -> String {
		switch key {
		case .esc: "esc"
		case .ctrl: "ctrl"
		case .alt: "alt"
		case .tab: "tab"
		case .shiftTab: "⇤tab"
		case .arrowUp: "▲"
		case .arrowDown: "▼"
		case .arrowLeft: "◀"
		case .arrowRight: "▶"
		case .home: "home"
		case .end: "end"
		case .pageUp: "pgUp"
		case .pageDown: "pgDn"
		case .insert: "ins"
		case .delete: "del"
		case .paste: "paste"
		case .function(let n): "F\(n)"
		case .control(let s): s == "\\" ? "^|" : "^\(s.uppercased())"
		case .altKey(let s): "Alt-\(s)"
		case .sequence: "^X^X"
		case .literal(let s): s
		}
	}
}
#endif
