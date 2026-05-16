#if canImport(UIKit)
import SwiftUI

/// The tool strip below the keyboard: snippets, history, theme, and the
/// native/custom keyboard toggle (the only place the toggle lives now).
struct TerminalToolbarView: View {
	@ObservedObject var model: TerminalScreenModel
	let snippets: [TerminalSnippet]
	@Binding var keyboardMode: TerminalKeyboardMode

	private enum Sheet: String, Identifiable {
		case snippets, theme, history
		var id: String { rawValue }
	}
	@State private var sheet: Sheet?

	var body: some View {
		HStack(spacing: 0) {
			toolButton("square.grid.2x2", "Snippets") { sheet = .snippets }
			Spacer()
			toolButton("clock", "History") { sheet = .history }
			Spacer()
			toolButton("paintpalette", "Theme") { sheet = .theme }
			Spacer()
			toolButton(
				keyboardMode == .custom ? "keyboard" : "keyboard.chevron.compact.down",
				"Toggle Keyboard"
			) {
				let next: TerminalKeyboardMode = keyboardMode == .custom ? .native : .custom
				keyboardMode = next
				model.setNativeKeyboard(next == .native)
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 8)
		.background(Color(.systemBackground))
		.overlay(Divider(), alignment: .top)
		.sheet(item: $sheet) { which in
			NavigationStack {
				switch which {
				case .snippets: snippetList
				case .history: historyList
				case .theme: themeList
				}
			}
			.presentationDetents([.medium, .large])
		}
	}

	private func toolButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Image(systemName: icon)
				.font(.title3)
				.frame(width: 44, height: 32)
		}
		.buttonStyle(.plain)
		.accessibilityLabel(label)
	}

	private var snippetList: some View {
		Group {
			if snippets.isEmpty {
				ContentUnavailableView("No Snippets", systemImage: "square.grid.2x2",
					description: Text("Saved snippets appear here."))
			} else {
				List(snippets) { snip in
					Button {
						model.runText(snip.command)
						sheet = nil
					} label: {
						VStack(alignment: .leading, spacing: 2) {
							Text(snip.name).font(.headline)
							Text(snip.command)
								.font(.system(.caption, design: .monospaced))
								.foregroundStyle(.secondary)
								.lineLimit(1)
						}
					}
				}
			}
		}
		.navigationTitle("Snippets")
		.toolbar { closeButton }
	}

	private var historyList: some View {
		Group {
			if model.recents.isEmpty {
				ContentUnavailableView("No History", systemImage: "clock",
					description: Text("Commands you run from here are remembered."))
			} else {
				List(model.recents, id: \.self) { cmd in
					Button {
						model.runText(cmd)
						sheet = nil
					} label: {
						Text(cmd)
							.font(.system(.body, design: .monospaced))
							.lineLimit(1)
					}
				}
			}
		}
		.navigationTitle("History")
		.toolbar { closeButton }
	}

	private var themeList: some View {
		List(TerminalTheme.presets) { theme in
			Button {
				model.applyTheme(theme)
			} label: {
				HStack {
					RoundedRectangle(cornerRadius: 5)
						.fill(Color(UIColor(hex: theme.background) ?? .black))
						.overlay(
							Text("Aa")
								.font(.system(.caption, design: .monospaced))
								.foregroundColor(Color(UIColor(hex: theme.foreground) ?? .white)))
						.frame(width: 44, height: 30)
					Text(theme.name)
					Spacer()
					if theme.id == model.theme.id {
						Image(systemName: "checkmark").foregroundStyle(.tint)
					}
				}
			}
			.buttonStyle(.plain)
		}
		.navigationTitle("Theme")
		.toolbar { closeButton }
	}

	@ToolbarContentBuilder private var closeButton: some ToolbarContent {
		ToolbarItem(placement: .confirmationAction) {
			Button("Done") { sheet = nil }
		}
	}
}
#endif
