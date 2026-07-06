import SwiftUI

/// The primary window/host shortcuts surfaced on the empty landing page.
enum ShortcutHints {
	static let primary: [(keys: String, label: String)] = [
		("⌘T", "New Tab"),
		("⌘N", "New Window"),
		("⇧⌘T", "New Host"),
		("⌘B", "Toggle Sidebar"),
		("⇧⌘F", "Files Drawer"),
		("⇧⌘P", "Snippets"),
	]
}

/// Persistent shortcut reference shown on the empty landing page, replacing
/// the old "Pick a host…" placeholder text.
struct ShortcutReferenceList: View {
	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			ForEach(ShortcutHints.primary, id: \.keys) { row in
				HStack(spacing: 10) {
					Text(row.keys)
						.font(.system(size: 12, weight: .semibold, design: .rounded))
						.foregroundStyle(.secondary)
						.padding(.horizontal, 6)
						.padding(.vertical, 2)
						.background(
							RoundedRectangle(cornerRadius: 5, style: .continuous)
								.fill(.quaternary)
						)
						.frame(width: 64, alignment: .trailing)
					Text(row.label)
						.font(.system(size: 12))
						.foregroundStyle(.secondary)
					Spacer(minLength: 0)
				}
			}
		}
		.fixedSize()
	}
}
