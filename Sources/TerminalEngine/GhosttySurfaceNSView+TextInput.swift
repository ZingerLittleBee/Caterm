import AppKit
import GhosttyKit

/// `NSTextInputClient` conformance for the libghostty surface host view.
///
/// Wires AppKit's IME pipeline into libghostty's preedit / commit API:
///   - `setMarkedText` mirrors the in-flight composition string into both
///     `markedString` (so `keyDown` can flip the `composing` flag) and
///     libghostty's preedit slot (rendered inline at the cursor).
///   - `insertText` commits the composed string via `surface_text` and
///     clears the preedit. The raw key that triggered the commit was
///     already forwarded by `keyDown` (with `composing: true`), so
///     libghostty knows not to double-emit it.
///   - `firstRect(forCharacterRange:)` reports the cursor anchor in screen
///     coordinates so AppKit can position the candidate panel near the
///     terminal cursor instead of the screen corner.
extension GhosttySurfaceNSView: @MainActor NSTextInputClient {

	public func insertText(_ string: Any, replacementRange: NSRange) {
		let s: String
		if let attr = string as? NSAttributedString {
			s = attr.string
		} else if let plain = string as? String {
			s = plain
		} else {
			s = ""
		}

		// Only handle genuine IME commits here (Pinyin / Hangul / dead-key
		// composition with non-empty `markedString`). Route those through
		// `ghostty_surface_text` since they're confirmed multi-char text
		// input — the same API libghostty uses for paste.
		//
		// For everything else (plain printable ASCII, control bytes from
		// Ctrl+letter, DEL, etc.), do nothing: `keyDown`'s
		// `surface.sendKey(event, composing: false)` runs after this and
		// libghostty's KeyEncoder produces the right bytes from the
		// `keycode` + `mods` + `unshifted_codepoint` triple. Routing
		// printable bytes through `sendText` would re-introduce the
		// bracketed-paste highlight that bash 5.x readline applies to
		// every paste-wrapped keystroke; routing control bytes through
		// `sendText` would deliver them as paste content and prevent bash
		// from interpreting Ctrl+C as SIGINT.
		if !markedString.isEmpty {
			if !s.isEmpty {
				surface?.sendText(s)
				surface?.setPreedit("")
			}
			markedString = ""
			// `sendText` already emitted the commit; keyDown must pass
			// `composing: true` so `sendKey` does not double-emit.
			imeConsumedThisEvent = true
		}
	}

	public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
		let s: String
		if let attr = string as? NSAttributedString {
			s = attr.string
		} else if let plain = string as? String {
			s = plain
		} else {
			s = ""
		}
		markedString = s
		surface?.setPreedit(s)
		imeConsumedThisEvent = true
	}

	public func unmarkText() {
		markedString = ""
		surface?.setPreedit("")
	}

	public func hasMarkedText() -> Bool { !markedString.isEmpty }

	public func markedRange() -> NSRange {
		markedString.isEmpty
			? NSRange(location: NSNotFound, length: 0)
			: NSRange(location: 0, length: markedString.utf16.count)
	}

	public func selectedRange() -> NSRange {
		NSRange(location: NSNotFound, length: 0)
	}

	public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
		nil
	}

	public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

	public func characterIndex(for point: NSPoint) -> Int { NSNotFound }

	public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
		guard let surface, let win = window else {
			return NSRect(origin: .zero, size: .zero)
		}
		let viewRect = surface.imePoint()
		let winRect = convert(viewRect, to: nil)
		return win.convertToScreen(winRect)
	}

	// `doCommand(by:)` is overridden as a true noop on `GhosttySurfaceNSView`
	// itself (see `GhosttySurfaceNSView.swift`). We can't put the override in
	// this extension because `NSTextInputClient` already declares
	// `doCommand(by:)`, and Swift requires the override to live on the
	// primary class to mark the method as overriding the `NSResponder`
	// default rather than introducing a fresh protocol-method definition.
}
