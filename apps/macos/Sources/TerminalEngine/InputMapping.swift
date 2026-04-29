import AppKit
import GhosttyKit

/// Pure mapping helpers between AppKit input events and libghostty C enums.
///
/// These intentionally have no `GhosttySurface` dependency so they can be unit
/// tested without a `@MainActor` context or a live surface handle.

/// Convert AppKit `NSEvent.ModifierFlags` into libghostty's `ghostty_input_mods_e`
/// bitmask. Unmapped bits (e.g. `.numericPad`, `.function`) are intentionally
/// dropped — libghostty has no equivalent.
public func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
	var raw: UInt32 = 0
	if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
	if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
	if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
	if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
	if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
	return ghostty_input_mods_e(raw)
}
