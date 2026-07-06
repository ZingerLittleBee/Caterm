import AppKit
import ConfigStore
import Foundation
import GhosttyKit
import SettingsStore

/// Wraps a single libghostty surface. Each surface owns its own PTY (started
/// by libghostty itself, not by us) and renders into the host `NSView` via
/// Metal.
///
/// Ownership / threading:
///   - The libghostty surface API is **not** thread-safe; all methods on this
///     class are `@MainActor`-isolated.
///   - C strings passed via `ghostty_surface_config_s` (command, env vars)
///     must outlive the call to `ghostty_surface_new`. We `strdup` them and
///     free in `deinit` to be safe — libghostty may copy internally, but we
///     don't rely on that.
///   - A static registry (`registry`) maps the underlying `ghostty_surface_t`
///     pointer to the Swift wrapper so the global C action callback can
///     dispatch back to us.
@MainActor
public final class GhosttySurface {
	public let raw: ghostty_surface_t
	public weak var hostView: NSView?

	/// Fired when libghostty reports the PTY child process has exited
	/// (`GHOSTTY_ACTION_SHOW_CHILD_EXITED`). Wired in Task 1.4 by SessionStore;
	/// Task 1.1 just declares the property and the surface won't fire it for
	/// `$SHELL` (which doesn't exit on its own).
	public var onChildExit: ((Int32) -> Void)?

	/// Fired exactly once, when the remote session emits its first OSC title
	/// or pwd sequence (`GHOSTTY_ACTION_SET_TITLE` / `GHOSTTY_ACTION_PWD`).
	/// That only happens once an interactive remote shell is actually up — an
	/// ssh auth/DNS failure exits before any shell starts and never emits it,
	/// so this is a precise "the session is live" signal and is safe to use
	/// to dismiss the connecting overlay immediately, without disturbing the
	/// exit-code-based failure classification.
	public var onSessionLive: (() -> Void)? {
		didSet {
			// Sticky signal: the surface is created lazily (in
			// `viewDidMoveToWindow`) and the ssh child starts at the same
			// moment, so the remote's first title/pwd can arrive BEFORE the
			// host has finished attaching this callback. `handleSessionLive`
			// latches `sessionLiveSignalled` regardless; if it already fired,
			// replay it the instant the callback lands instead of losing the
			// signal and waiting out the grace timer.
			if sessionLiveSignalled, onSessionLive != nil {
				onSessionLive?()
			}
		}
	}
	private var sessionLiveSignalled = false

	/// Fired when libghostty asks the apprt to change the mouse cursor shape
	/// (`GHOSTTY_ACTION_MOUSE_SHAPE`). The host view translates this into an
	/// `NSCursor`.
	public var onMouseShape: ((ghostty_action_mouse_shape_e) -> Void)?
	/// Fired when libghostty asks the apprt to hide / show the cursor
	/// (`GHOSTTY_ACTION_MOUSE_VISIBILITY`).
	public var onMouseVisibility: ((ghostty_action_mouse_visibility_e) -> Void)?

	/// Fired when the pointer hovers over (or leaves) a detected URL in the
	/// terminal grid (`GHOSTTY_ACTION_MOUSE_OVER_LINK`). The payload is the
	/// URL string, or `nil` when the hover ends. The host view uses this to
	/// flip to `NSCursor.pointingHand` when the user holds ⌘.
	public var onHoverURL: ((String?) -> Void)?
	/// Fired when libghostty asks the apprt to open a URL
	/// (`GHOSTTY_ACTION_OPEN_URL`), typically after a ⌘-click on a hovered
	/// link. The host view routes this to `NSWorkspace.open` after a scheme
	/// whitelist check.
	public var onOpenURL: ((String, ghostty_action_open_url_kind_e) -> Void)?

	/// Drag-drop bridge: when set, `read_clipboard_cb` returns this string
	/// instead of reading the system pasteboard. Cleared after each consume.
	public var pendingPasteText: String?

	/// Token raised right before triggering libghostty's
	/// `paste_from_clipboard` binding action. Distinguishes a local paste
	/// (consume the system pasteboard or `pendingPasteText`) from a remote
	/// OSC 52 read (denied in v1.5).
	public var pendingLocalPaste: Bool = false

	private(set) public var processExited: Bool = false

	/// Pixel dimensions of one terminal cell, updated by
	/// `GHOSTTY_ACTION_CELL_SIZE`. The default is a sane fallback used for
	/// imprecise wheel-scroll deltas before libghostty reports a real value.
	public private(set) var cellSize: NSSize = .init(width: 8, height: 16)

	/// Heap-allocated C strings whose pointers were stuffed into the surface
	/// config. Held here so we can free them when the surface dies.
	private var ownedCStrings: [UnsafeMutablePointer<CChar>] = []
	/// Backing storage for `ghostty_env_var_s` array, if any.
	private var envStorage: UnsafeMutablePointer<ghostty_env_var_s>?
	private var envStorageCount: Int = 0

	// MARK: - Registry
	//
	// libghostty hands us back `ghostty_target_s` containing a raw surface
	// pointer (`ghostty_surface_t`). To dispatch back to the Swift wrapper
	// from the static C action callback, we keep a process-wide table.

	private static var registry: [OpaquePointer: GhosttySurface] = [:]

	static func lookup(_ raw: ghostty_surface_t?) -> GhosttySurface? {
		guard let raw else { return nil }
		return registry[OpaquePointer(raw)]
	}

	public init(
		hostView: NSView,
		command: String? = nil,
		env: [(String, String)] = []
	) throws {
		self.hostView = hostView

		var surfaceConfig = ghostty_surface_config_new()
		surfaceConfig.userdata = Unmanaged.passUnretained(hostView).toOpaque()
		surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
		surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
			nsview: Unmanaged.passUnretained(hostView).toOpaque()
		))
		let scale = hostView.window?.backingScaleFactor
			?? NSScreen.main?.backingScaleFactor
			?? 2.0
		surfaceConfig.scale_factor = Double(scale)
		surfaceConfig.font_size = 0 // inherit from config
		surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

		// Keep references to any C strings we hand to libghostty so they
		// outlive the call. libghostty may or may not copy; we assume it
		// does not.
		var ownedStrings: [UnsafeMutablePointer<CChar>] = []

		if let command {
			let dup = strdup(command)!
			ownedStrings.append(dup)
			surfaceConfig.command = UnsafePointer(dup)
		}
		// When `command == nil`, we deliberately leave `surfaceConfig.command`
		// as the zero-init value (NULL) so libghostty falls back to `$SHELL`.

		// Optional env var array. Allocated as a contiguous C array; freed in
		// `deinit` along with each key/value strdup.
		var envBuffer: UnsafeMutablePointer<ghostty_env_var_s>?
		if !env.isEmpty {
			let count = env.count
			let buf = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: count)
			for (idx, pair) in env.enumerated() {
				let keyDup = strdup(pair.0)!
				let valDup = strdup(pair.1)!
				ownedStrings.append(keyDup)
				ownedStrings.append(valDup)
				buf[idx] = ghostty_env_var_s(key: UnsafePointer(keyDup), value: UnsafePointer(valDup))
			}
			surfaceConfig.env_vars = buf
			surfaceConfig.env_var_count = count
			envBuffer = buf
		}

		guard let surfaceHandle = ghostty_surface_new(GhosttyApp.shared.raw, &surfaceConfig) else {
			// Free anything we allocated before throwing.
			for ptr in ownedStrings { free(ptr) }
			if let buf = envBuffer { buf.deallocate() }
			throw GhosttyError.surfaceCreateFailed
		}

		self.raw = surfaceHandle
		self.ownedCStrings = ownedStrings
		self.envStorage = envBuffer
		self.envStorageCount = env.count

		Self.registry[OpaquePointer(surfaceHandle)] = self
	}

	deinit {
		// `deinit` runs on whichever thread released the last strong ref; it
		// is not @MainActor isolated. Hop to the main actor to touch the
		// libghostty handle and the registry, both of which are main-only.
		// We capture the raw pointers (Sendable) by value so we don't need to
		// pass `self` across the boundary.
		let surfaceHandle = raw
		let strings = ownedCStrings
		let envBuf = envStorage
		MainActor.assumeIsolated {
			Self.registry.removeValue(forKey: OpaquePointer(surfaceHandle))
			ghostty_surface_free(surfaceHandle)
		}
		for ptr in strings { free(ptr) }
		if let buf = envBuf { buf.deallocate() }
	}

	// MARK: - Public API

	public func setSize(width: UInt32, height: UInt32) {
		ghostty_surface_set_size(raw, width, height)
	}

	/// Applies the per-host theme patch on top of the user/managed config to
	/// the live surface. No-op when the per-host patch file is absent.
	///
	/// Load order (matches Task 17 ordering): defaults → managed → user → per-host.
	/// Callers invoke this AFTER constructing the surface (Task 18). It is
	/// not auto-called from `init` to keep the trigger explicit and to match
	/// the production wiring where the host id is known at the call site.
	public func applyPerHostPatch(hostId: HostId, userConfigPath: String? = nil) {
		let path = ConfigStore.perHostPatchPath(for: hostId)
		guard FileManager.default.fileExists(atPath: path.path) else { return }
		applyConfig(hostId: hostId, userConfigPath: userConfigPath)
	}

	/// Rebuilds the Ghostty config stack from disk and applies it to this live
	/// surface. This mirrors Ghostty's reload flow: defaults → Caterm managed
	/// snapshot → user config → optional per-host patch.
	@discardableResult
	public func applyConfig(
		hostId: HostId? = nil,
		userConfigPath: String? = ConfigStore.defaultPath.path
	) -> [ConfigDiagnostic] {
		let perHostPath = hostId.map { ConfigStore.perHostPatchPath(for: $0).path }
		let cfg: ghostty_config_t
		do {
			cfg = try GhosttyConfigLoader.make(
				catermConfigPath: userConfigPath,
				perHostConfigPath: perHostPath
			)
		} catch {
			return [ConfigDiagnostic(message: "Ghostty surface config reload failed: \(error)")]
		}
		let diagnostics = ConfigDiagnostic.collect(from: cfg)
		ghostty_surface_update_config(raw, cfg)
		ghostty_config_free(cfg)
		return diagnostics
	}

	public func setContentScale(_ scale: CGFloat) {
		ghostty_surface_set_content_scale(raw, scale, scale)
	}

	public func setFocus(_ focused: Bool) {
		ghostty_surface_set_focus(raw, focused)
	}

	/// Forwards an `NSEvent` keyDown/keyUp to libghostty. Mirrors the spike's
	/// mapping: keycode + modifier flags + raw text payload, plus the
	/// unshifted codepoint. libghostty handles binding lookup, IME, and PTY
	/// write internally.
	///
	/// `composing` should be `true` when the host view has marked text
	/// (i.e. the user is in the middle of an IME composition session). When
	/// set, libghostty knows the key is part of the IME flow and will not
	/// double-emit it as text — the actual commit comes through
	/// `sendText` from `NSTextInputClient.insertText`.
	public func sendKey(_ event: NSEvent, composing: Bool = false) {
		let mods = ghosttyMods(event.modifierFlags)
		// `consumed_mods` reports which modifiers the macOS layout already
		// consumed to produce `event.characters`. libghostty subtracts these
		// from `mods` to get the "effective" mods for protocol encoding.
		// Crucially: never report Ctrl or Cmd as consumed — the layout never
		// uses them for character translation (they're terminal/shortcut
		// modifiers). Reporting them as consumed cancels them out and forces
		// libghostty into Kitty CSI-u fallback (`\e[<cp>;<mods>u`) for
		// Ctrl+letter, which non-Kitty shells echo back as literal text.
		// Shift/Option/CapsLock are assumed consumed by translation.
		let consumedFlags = event.modifierFlags.subtracting([.control, .command])
		let consumedMods = ghosttyMods(consumedFlags)
		let action: ghostty_input_action_e = event.isARepeat
			? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

		// `unshifted_codepoint` = codepoint produced with NO modifiers at all
		// (Shift stripped too, unlike `charactersIgnoringModifiers`).
		// libghostty's KeyEncoder uses this to derive control bytes for
		// Ctrl+letter (Ctrl+C needs unshifted='c'=99 to emit \x03).
		var unshifted: UInt32 = 0
		if let bare = event.characters(byApplyingModifiers: []),
			let scalar = bare.unicodeScalars.first {
			unshifted = scalar.value
		}

		// `text` payload is only attached when `event.characters` is a
		// printable codepoint (>= 0x20) AND not a function-key PUA value.
		// For control bytes (Ctrl+letter producing \x01-\x1F) and arrow /
		// function keys (NSUpArrowFunctionKey etc., in 0xF700-0xF8FF), we
		// pass `text = nil` and let libghostty encode from `keycode` + mods.
		// This matches Ghostty's macOS apprt and avoids double-emission.
		let textPayload: String? = {
			guard let chars = event.characters,
				let scalar = chars.unicodeScalars.first else { return nil }
			if scalar.value < 0x20 { return nil }
			if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
			return chars
		}()

		var k = ghostty_input_key_s()
		k.action = action
		k.mods = mods
		k.consumed_mods = consumedMods
		// libghostty's macOS path expects the raw `NSEvent.keyCode`
		// (HID/AppKit virtual keycode), NOT a `ghostty_input_key_e` value —
		// it does the translation internally.
		k.keycode = UInt32(event.keyCode)
		k.unshifted_codepoint = unshifted
		k.composing = composing

		if let textPayload {
			textPayload.withCString { ptr in
				k.text = ptr
				_ = ghostty_surface_key(raw, k)
			}
		} else {
			k.text = nil
			_ = ghostty_surface_key(raw, k)
		}
	}

	// MARK: - Internal hooks (called by the global action callback)

	func handleChildExited(exitCode: UInt32) {
		processExited = true
		onChildExit?(Int32(bitPattern: exitCode))
	}

	/// Latched: the remote shell emits many title/pwd updates over a session;
	/// only the first one means "we just went live". If the callback isn't
	/// attached yet, the latch persists and `onSessionLive`'s `didSet` replays
	/// it on attach (see the property above).
	func handleSessionLive() {
		guard !sessionLiveSignalled else { return }
		sessionLiveSignalled = true
		onSessionLive?()
	}

	func updateCellSize(width: Double, height: Double) {
		cellSize = NSSize(width: width, height: height)
	}

	func handleMouseShape(_ shape: ghostty_action_mouse_shape_e) {
		onMouseShape?(shape)
	}

	func handleMouseVisibility(_ visibility: ghostty_action_mouse_visibility_e) {
		onMouseVisibility?(visibility)
	}

	func handleHoverURL(_ url: String?) {
		onHoverURL?(url)
	}

	func handleOpenURL(_ url: String, kind: ghostty_action_open_url_kind_e) {
		onOpenURL?(url, kind)
	}

}
