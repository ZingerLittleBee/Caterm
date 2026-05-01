import Foundation
import SettingsStore

public enum SettingsRenderer {
    public static let header = "# managed by Caterm — do not edit; use Caterm Preferences (⌘,)"

    public static let legacyBlock = """
        # Default to xterm-256color so SSH sessions to hosts without the
        # xterm-ghostty terminfo entry installed don't fail.
        term = xterm-256color

        keybind = super+up=scroll_page_lines:-1
        keybind = super+down=scroll_page_lines:1
        keybind = super+page_up=scroll_page_fractional:-1
        keybind = super+page_down=scroll_page_fractional:1
        keybind = super+home=scroll_to_top
        keybind = super+end=scroll_to_bottom
        keybind = super+k=clear_screen
        """

    public static func render(_ s: PartialSettings) -> String {
        var lines: [String] = []
        lines.append(header)
        lines.append("")
        lines.append(legacyBlock)
        lines.append("")

        if let v = s.fontFamily { lines.append("font-family = \(v)") }
        if let v = s.fontSize { lines.append("font-size = \(v)") }
        if let v = s.lineHeight { lines.append("adjust-cell-height = \(formatPercent(v))") }
        if let v = s.cursorStyle { lines.append("cursor-style = \(v.rawValue)") }
        if let v = s.cursorBlink { lines.append("cursor-style-blink = \(v)") }
        if let v = s.bell { lines.append("bell-features = \(renderBell(v))") }
        if let v = s.scrollbackBytes { lines.append("scrollback-limit = \(v)") }
        if let v = s.windowOpacity { lines.append("background-opacity = \(formatDouble(v))") }
        if let v = s.windowPaddingX { lines.append("window-padding-x = \(v)") }
        if let v = s.windowPaddingY { lines.append("window-padding-y = \(v)") }
        if let v = s.titlebarStyle { lines.append("macos-titlebar-style = \(v.rawValue)") }
        if let v = s.theme { lines.append("theme = \(v)") }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatPercent(_ d: Double) -> String {
        let pct = Int(((d - 1.0) * 100).rounded())
        return "\(pct)%"
    }

    private static func formatDouble(_ d: Double) -> String {
        let s = String(format: "%.2f", d)
        if s.hasSuffix("0") { return String(s.dropLast()) }
        return s
    }

    private static func renderBell(_ mode: BellMode) -> String {
        switch mode {
        case .none:    return "no-system,no-audio,no-attention,no-title,no-border"
        case .audio:   return "no-system,audio,no-attention,no-title,no-border"
        case .visual:  return "no-system,no-audio,attention,title,no-border"
        case .both:    return "no-system,audio,attention,title,no-border"
        }
    }
}
