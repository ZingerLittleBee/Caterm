import AppKit
import GhosttyKit

/// `NSView` host for a `GhosttySurface`. Owns the surface, forwards key events
/// into it, and propagates resize / scale changes back to libghostty.
///
/// libghostty paints into this view's `CAMetalLayer` (created on demand via
/// `wantsLayer`). We don't draw anything ourselves.
@MainActor
public final class GhosttySurfaceNSView: NSView {
	public private(set) var surface: GhosttySurface?

	private let pendingCommand: String?
	private let pendingEnv: [(String, String)]
	private let pendingWorkingDirectory: URL?
	private let createsSurfaceOnAttach: Bool
	private var didCreateSurface = false
	private var backgroundTransparencyEnabled = false
	private var paneFocusRequested = true

	public var onFirstResponderChange: ((Bool) -> Void)?

	/// Last shape libghostty asked us to render. Updated by
	/// `GhosttySurface.onMouseShape`; consumed by `cursorUpdate(with:)` to
	/// pick an `NSCursor`.
	var currentMouseShape: ghostty_action_mouse_shape_e = GHOSTTY_MOUSE_SHAPE_TEXT

	/// In-flight IME composition string. Mirrored from AppKit's
	/// `setMarkedText` so `keyDown` can decide whether to set the
	/// `composing` flag on libghostty's key event. Lives on the class
	/// (Swift extensions can't add stored properties) and is `internal`
	/// rather than `private` because the `NSTextInputClient` conformance
	/// reads/writes it from `GhosttySurfaceNSView+TextInput.swift`.
	var markedString: String = ""

	/// URL the pointer is currently hovering over, as reported by
	/// `GHOSTTY_ACTION_MOUSE_OVER_LINK`. `nil` when the pointer is not over
	/// a link. Read by `cursorUpdate(with:)` to flip to `pointingHand` when
	/// ⌘ is held; written by `GhosttySurfaceNSView+URL.swift` (so it must
	/// be at least `internal`, not `private`).
	var hoveredURL: String?

	/// Set to `true` by `insertText` / `setMarkedText` (the
	/// `NSTextInputClient` bridge in `+TextInput.swift`) when AppKit's IME
	/// pipeline produced text or preedit during the current `keyDown`. Read
	/// by `keyDown` to decide the `composing` flag on the libghostty
	/// `sendKey` call: when AppKit already routed the text via the IME
	/// path, libghostty must not re-emit it.
	var imeConsumedThisEvent: Bool = false

	public convenience init(
		command: String?,
		env: [(String, String)] = [],
		workingDirectory: URL? = nil
	) {
		self.init(
			command: command,
			env: env,
			workingDirectory: workingDirectory,
			createsSurfaceOnAttach: true
		)
	}

	init(
		command: String?,
		env: [(String, String)] = [],
		workingDirectory: URL? = nil,
		createsSurfaceOnAttach: Bool
	) {
		self.pendingCommand = command
		self.pendingEnv = env
		self.pendingWorkingDirectory = workingDirectory
		self.createsSurfaceOnAttach = createsSurfaceOnAttach
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
		wantsLayer = true
		registerForDraggedTypes([.fileURL, .string])
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) is not supported")
	}

	public override var acceptsFirstResponder: Bool { true }
	public override var canBecomeKeyView: Bool { true }
	public override var isFlipped: Bool { true }
	public override var wantsUpdateLayer: Bool { true }

	public override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		applyBackgroundTransparency()
		guard createsSurfaceOnAttach else {
			requestPaneFocusIfNeeded()
			return
		}
		guard !didCreateSurface, window != nil else { return }
		do {
			let surface = try GhosttySurface(
				hostView: self,
				command: pendingCommand,
				env: pendingEnv,
				workingDirectory: pendingWorkingDirectory
			)
			self.surface = surface
			didCreateSurface = true
			surface.onMouseShape = { [weak self] shape in
				guard let self else { return }
				self.currentMouseShape = shape
				// Set the cursor right now rather than waiting for AppKit's
				// next `cursorUpdate(with:)` call. `invalidateCursorRects`
				// only schedules a `resetCursorRects()`, which we don't
				// override — so without an explicit `.set()` here the
				// cursor would lag by one mouse-motion event. The
				// `cursorUpdate(with:)` override stays as the path for
				// tracking-area entry events.
				self.nsCursor(for: shape).set()
			}
			surface.onMouseVisibility = { visibility in
				if visibility == GHOSTTY_MOUSE_HIDDEN {
					NSCursor.hide()
				} else {
					NSCursor.unhide()
				}
			}
			wireURLHandlers()
			requestPaneFocusIfNeeded()
			propagateSize()
			applyBackgroundTransparency()
			surface.setFocus(window?.firstResponder === self)
		} catch {
			// Surfacing this through the UI is Task 1.4's job; for the smoke
			// path we just log and let the window stay blank.
			NSLog("[TerminalEngine] surface creation failed: \(error)")
		}
	}

	public override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		guard didCreateSurface else { return }
		propagateSize()
	}

	public override func becomeFirstResponder() -> Bool {
		let accepted = super.becomeFirstResponder()
		if accepted {
			surface?.setFocus(true)
			onFirstResponderChange?(true)
		}
		return accepted
	}

	public override func resignFirstResponder() -> Bool {
		let accepted = super.resignFirstResponder()
		if accepted {
			surface?.setFocus(false)
			onFirstResponderChange?(false)
		}
		return accepted
	}

	public func setPaneFocusRequested(_ requested: Bool) {
		paneFocusRequested = requested
		if !requested, window?.firstResponder === self {
			window?.makeFirstResponder(nil)
			return
		}
		requestPaneFocusIfNeeded()
	}

	private func requestPaneFocusIfNeeded() {
		guard paneFocusRequested,
		      let window,
		      window.firstResponder !== self else { return }
		window.makeFirstResponder(self)
	}

	public override func keyDown(with event: NSEvent) {
		guard let surface else {
			super.keyDown(with: event)
			return
		}
		// Run AppKit's text-input pipeline FIRST. `interpretKeyEvents` will:
		//   - call `insertText` for plain printables AND for IME commits,
		//   - call `setMarkedText` while an IME composition is in flight,
		//   - dispatch named selectors (`deleteBackward:`, `insertNewline:`,
		//     `moveToBeginningOfLine:`, …) via `doCommand(by:)` for non-text
		//     keys.
		//
		// Our `+TextInput.swift` bridge sets `imeConsumedThisEvent = true`
		// inside `insertText` / `setMarkedText` so we can tell, on return,
		// whether AppKit already produced text for this keystroke. Our
		// `doCommand(by:)` override is a true noop — that silences the
		// system beep AppKit emits when no responder handles a selector,
		// while letting the same physical key reach the PTY through the
		// `sendKey` call below.
		imeConsumedThisEvent = false
		interpretKeyEvents([event])

		// Forward the raw event to libghostty.
		//
		// `composing: true` when AppKit's IME path already produced text or
		// is mid-composition — libghostty tracks the keystroke for the
		// keyboard protocol but does not re-emit text or run binding lookup.
		// `composing: false` otherwise — libghostty owns binding matching
		// and PTY emission for that key (Backspace → DEL, Enter → CR,
		// Ctrl-A → \x01, etc.).
		let imeInvolved = imeConsumedThisEvent || hasMarkedText()
		surface.sendKey(event, composing: imeInvolved)
	}

	public override func doCommand(by selector: Selector) {
		// Silently consume every AppKit text-action selector
		// (`deleteBackward:`, `insertNewline:`, `cancelOperation:`,
		// `moveLeft:`, `moveToBeginningOfLine:`, etc.). The corresponding
		// PTY action is delivered by the `surface.sendKey(...)` call in
		// `keyDown`; libghostty owns binding matching and protocol encoding
		// for these keys. If we instead inherited NSResponder's default,
		// AppKit would beep when nothing handles the selector.
	}

	public override func cursorUpdate(with event: NSEvent) {
		// URL-hover takes priority over libghostty's mouse-shape: while ⌘ is
		// held over a detected link the pointer must read as a click target
		// (pointing hand) regardless of what shape libghostty is currently
		// asking for. Otherwise fall back to the shape mapping from Task 1.
		if hoveredURL != nil, NSEvent.modifierFlags.contains(.command) {
			NSCursor.pointingHand.set()
		} else {
			nsCursor(for: currentMouseShape).set()
		}
	}

	public override func flagsChanged(with event: NSEvent) {
		// Re-publish pointer position with the new modifier set so
		// libghostty can recompute hover state — pressing ⌘ over text that
		// happens to be a URL must promote it to a hovered link, and
		// releasing ⌘ must demote it. Without this, the user would have to
		// also nudge the mouse for libghostty to notice the modifier flip.
		if let surface {
			let p = convert(event.locationInWindow, from: nil)
			surface.sendMousePos(x: Double(p.x), y: Double(p.y), mods: event.modifierFlags)
		}
		// Nudge AppKit to re-call `cursorUpdate(with:)` so the pointing-hand
		// flip happens promptly when ⌘ is pressed/released without motion.
		window?.invalidateCursorRects(for: self)
		super.flagsChanged(with: event)
	}

	public func setBackgroundTransparencyEnabled(_ enabled: Bool) {
		backgroundTransparencyEnabled = enabled
		applyBackgroundTransparency()
	}

	/// Map libghostty's cursor-shape enum onto `NSCursor`. Unmapped shapes
	/// fall back to `.arrow`; see ghostty.h ~line 685 for the full list.
	private func nsCursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
		switch shape {
		case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
			return .iBeam
		case GHOSTTY_MOUSE_SHAPE_POINTER:
			return .pointingHand
		case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
			return .crosshair
		case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
			return .operationNotAllowed
		default:
			return .arrow
		}
	}

	private func propagateSize() {
		guard let surface else { return }
		let scaled = convertToBacking(bounds.size)
		let width = UInt32(max(1, scaled.width))
		let height = UInt32(max(1, scaled.height))
		surface.setSize(width: width, height: height)
	}

	private func applyBackgroundTransparency() {
		TerminalWindowTransparency.apply(
			enabled: backgroundTransparencyEnabled,
			to: window,
			layer: layer
		)
	}
}
