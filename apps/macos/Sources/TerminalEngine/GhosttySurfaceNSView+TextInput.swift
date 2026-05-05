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
extension GhosttySurfaceNSView: NSTextInputClient {

	public func insertText(_ string: Any, replacementRange: NSRange) {
		let s: String
		if let attr = string as? NSAttributedString {
			s = attr.string
		} else if let plain = string as? String {
			s = plain
		} else {
			s = ""
		}

		// AppKit calls `insertText` for two distinct flows:
		//
		//   1. Genuine IME commit — the user just confirmed a multi-char
		//      composition (Pinyin, Hangul, US-Intl dead-key, etc.).
		//      Detected by `!markedString.isEmpty` (preedit was in flight).
		//      Route through `ghostty_surface_text` so libghostty treats it
		//      as confirmed text input.
		//
		//   2. Plain printable keystroke — `interpretKeyEvents` calls
		//      `insertText` directly for ASCII keys with no composition,
		//      with `markedString` empty. Routing this through
		//      `ghostty_surface_text` is wrong: libghostty wraps that path
		//      in bracketed-paste delimiters when the application enabled
		//      `\e[?2004h` (default in bash 5.x). bash's readline then
		//      treats every keystroke as a one-char paste and applies
		//      `active-region-start-color` (inverse video) to it — visible
		//      as a "white background on the last typed char" artifact.
		//      Skip the IME path entirely for this case and let
		//      `keyDown`'s `surface.sendKey(event, composing: false)`
		//      emit the byte through libghostty's regular key path.
		let wasComposing = !markedString.isEmpty
		if wasComposing {
			if !s.isEmpty {
				surface?.sendText(s)
				surface?.setPreedit("")
			}
			markedString = ""
			// IME path produced text — `keyDown` must set `composing: true`
			// so libghostty does not re-emit the raw key as text.
			imeConsumedThisEvent = true
		}
		// else: plain typing — leave `imeConsumedThisEvent = false` so
		// `keyDown` calls `sendKey(composing: false)` and libghostty
		// emits the raw key bytes itself.
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
