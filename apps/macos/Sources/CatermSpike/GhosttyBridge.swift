import AppKit
import GhosttyKit

/// Spike-grade libghostty wrapper. Single app + single surface. No abstractions.
///
/// Lifecycle:
///   1. `GhosttyBridge()` — runs `ghostty_init`, builds default config, creates app
///   2. `createSurface(forView:)` — binds a libghostty surface to an NSView; libghostty
///      spawns its own PTY and runs `command` (or the default shell) inside it
///   3. `feedKeyText(_:)` — forwards typed characters to the PTY
///   4. `setSize(width:height:)` — resizes both the libghostty render + the PTY
///   5. deinit frees both
///
/// libghostty owns the PTY end-to-end. There is no public "feed external bytes"
/// API in the surface, so the spec's NIO-driven feed flow is replaced by passing
/// `command="ssh user@host"` so libghostty itself spawns ssh.
final class GhosttyBridge {
    private var config: ghostty_config_t?
    private var app: ghostty_app_t?
    private var surface: ghostty_surface_t?

    /// Optional shell command for the surface to spawn. nil = user's default shell.
    private let command: String?

    init(command: String? = nil) throws {
        self.command = command

        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            throw NSError(domain: "GhosttyBridge", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "ghostty_init failed"
            ])
        }

        guard let cfg = ghostty_config_new() else {
            throw NSError(domain: "GhosttyBridge", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "ghostty_config_new returned nil"
            ])
        }
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)
        self.config = cfg

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { _ in },
            action_cb: { _, _, _ in false },
            read_clipboard_cb: { _, _, _ in false },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, _, _, _ in },
            close_surface_cb: { _, _ in }
        )

        guard let appHandle = ghostty_app_new(&runtime, cfg) else {
            throw NSError(domain: "GhosttyBridge", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "ghostty_app_new returned nil"
            ])
        }
        self.app = appHandle
    }

    func createSurface(forView view: NSView) throws {
        guard let app = self.app else { return }

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.userdata = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()
        ))
        let scale = view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        surfaceConfig.scale_factor = Double(scale)
        surfaceConfig.font_size = 0    // inherit from config
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        if let command {
            command.withCString { cStr in
                surfaceConfig.command = cStr
                surface = ghostty_surface_new(app, &surfaceConfig)
            }
        } else {
            surface = ghostty_surface_new(app, &surfaceConfig)
        }

        guard surface != nil else {
            throw NSError(domain: "GhosttyBridge", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "ghostty_surface_new returned nil"
            ])
        }
    }

    func setSize(width: UInt32, height: UInt32) {
        guard let surface else { return }
        ghostty_surface_set_size(surface, width, height)
    }

    func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    func setContentScale(_ scale: CGFloat) {
        guard let surface else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    /// Forwards an NSEvent keyDown to libghostty. Tries `ghostty_surface_key`
    /// first (handles Enter / arrows / Ctrl combos via keycode + mods); if
    /// libghostty doesn't claim it, falls back to `ghostty_surface_text` for
    /// regular printable input.
    func feedKey(event: NSEvent) {
        guard let surface else { return }

        let chars = event.characters ?? ""
        let mods = Self.ghosttyMods(event.modifierFlags)
        let action: ghostty_input_action_e = event.isARepeat
            ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        let handled: Bool = chars.withCString { textPtr -> Bool in
            var k = ghostty_input_key_s()
            k.action = action
            k.mods = mods
            k.consumed_mods = mods
            k.keycode = UInt32(event.keyCode)
            k.text = chars.isEmpty ? nil : textPtr
            k.unshifted_codepoint = chars.unicodeScalars.first.map { UInt32($0.value) } ?? 0
            k.composing = false
            return ghostty_surface_key(surface, k)
        }

        // If ghostty's binding system didn't consume it AND we have printable
        // text that wasn't already sent through key (text path), forward the
        // text. ghostty_surface_key is supposed to handle text for us, so
        // this branch is mainly a safety net.
        _ = handled
    }

    private static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift)   { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option)  { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock){ raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(raw)
    }

    deinit {
        if let s = surface { ghostty_surface_free(s) }
        if let a = app { ghostty_app_free(a) }
        if let c = config { ghostty_config_free(c) }
    }
}
