#if canImport(UIKit)
import SwiftUI

struct TerminalKeyBarView: View {
	@ObservedObject var model: TerminalScreenModel

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				ForEach(Array(model.keyBar.primaryRow.enumerated()), id: \.offset) { _, key in
					keyButton(key)
				}
				Divider().frame(height: 24)
				ForEach(Array(model.keyBar.secondaryRow.enumerated()), id: \.offset) { _, key in
					keyButton(key)
				}
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 6)
		}
		.background(.bar)
	}

	@ViewBuilder private func keyButton(_ key: TerminalKeyBar.Key) -> some View {
		Button {
			model.tapKey(key)
		} label: {
			Text(label(for: key))
				.font(.system(.callout, design: .monospaced))
				.frame(minWidth: 34, minHeight: 30)
				.background(
					(key == .ctrl && model.keyBar.isCtrlActive)
						? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15),
					in: RoundedRectangle(cornerRadius: 6))
		}
		.buttonStyle(.plain)
		.accessibilityLabel(accessibility(for: key))
	}

	private func label(for key: TerminalKeyBar.Key) -> String {
		switch key {
		case .esc: "esc"
		case .ctrl: "ctrl"
		case .tab: "tab"
		case .arrowUp: "↑"
		case .arrowDown: "↓"
		case .arrowLeft: "←"
		case .arrowRight: "→"
		case .home: "home"
		case .end: "end"
		case .pageUp: "pgup"
		case .pageDown: "pgdn"
		case .literal(let s): s
		}
	}

	private func accessibility(for key: TerminalKeyBar.Key) -> String {
		if case .literal(let s) = key { return "Key \(s)" }
		return label(for: key)
	}
}
#endif
