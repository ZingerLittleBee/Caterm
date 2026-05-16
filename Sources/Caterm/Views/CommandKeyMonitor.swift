import AppKit
import Combine
import SwiftUI

/// Publishes whether the ⌘ (Command) modifier is currently held down.
///
/// Drives the "hold ⌘ to reveal keyboard shortcuts" affordance: views can
/// observe `isCommandHeld` and surface inline shortcut badges/hints while
/// the key is down, then hide them again on release — mirroring the macOS
/// behavior of revealing accelerators on modifier hold.
///
/// Uses both a local and a global `flagsChanged` monitor so the state stays
/// correct whether or not the Caterm window is key. The state is also
/// reconciled from `NSEvent.modifierFlags` on every event so a missed
/// key-up (e.g. app deactivation while ⌘ is down) self-heals.
@MainActor
final class CommandKeyMonitor: ObservableObject {
	@Published private(set) var isCommandHeld = false

	private var localMonitor: Any?
	private var globalMonitor: Any?

	init() {
		let handler: @MainActor (NSEvent) -> Void = { [weak self] _ in
			self?.refresh()
		}
		localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
			handler(event)
			return event
		}
		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
			handler(event)
		}
	}

	deinit {
		if let localMonitor { NSEvent.removeMonitor(localMonitor) }
		if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
	}

	private func refresh() {
		let held = NSEvent.modifierFlags.contains(.command)
		if held != isCommandHeld { isCommandHeld = held }
	}
}

/// Compact reference of the primary window/host shortcuts, revealed at the
/// bottom of the sidebar while ⌘ is held.
struct ShortcutHintBar: View {
	private let rows: [(String, String)] = [
		("⌘T", "New Tab"),
		("⌘N", "New Window"),
		("⇧⌘T", "New Host"),
		("⌘B", "Toggle Sidebar"),
		("⇧⌘F", "Files Drawer"),
		("⇧⌘P", "Snippets"),
	]

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			ForEach(rows, id: \.0) { keys, label in
				HStack(spacing: 8) {
					Text(keys)
						.font(.system(size: 10, weight: .semibold, design: .rounded))
						.frame(width: 38, alignment: .leading)
						.foregroundStyle(.primary)
					Text(label)
						.font(.system(size: 10))
						.foregroundStyle(.secondary)
					Spacer(minLength: 0)
				}
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.quaternary)
		.transition(.opacity)
		.accessibilityHidden(true)
	}
}

/// Small pill rendered over an actionable control to reveal its keyboard
/// shortcut while ⌘ is held. Used as an `.overlay` so it never affects the
/// host control's layout.
struct ShortcutBadge: View {
	let keys: String

	var body: some View {
		Text(keys)
			.font(.system(size: 9, weight: .semibold, design: .rounded))
			.foregroundStyle(.white)
			.padding(.horizontal, 4)
			.padding(.vertical, 1)
			.background(
				RoundedRectangle(cornerRadius: 4, style: .continuous)
					.fill(Color.accentColor)
			)
			.fixedSize()
			.transition(.opacity.combined(with: .scale))
			.accessibilityHidden(true)
	}
}
