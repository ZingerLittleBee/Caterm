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

    /// Spike-grade text input: forwards UTF-8 bytes to the PTY. Good enough for
    /// "echo hi" + Return. Real implementation needs `ghostty_surface_key` for
    /// modifiers, arrow keys, Ctrl-C, etc.
    func feedKeyText(_ string: String) {
        guard let surface, !string.isEmpty else { return }
        let utf8 = Array(string.utf8)
        utf8.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: buf.count) { cBase in
                ghostty_surface_text(surface, cBase, UInt(buf.count))
            }
        }
    }

    deinit {
        if let s = surface { ghostty_surface_free(s) }
        if let a = app { ghostty_app_free(a) }
        if let c = config { ghostty_config_free(c) }
    }
}
