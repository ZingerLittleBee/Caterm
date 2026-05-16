import Foundation

/// A small built-in palette for the in-terminal theme picker. Kept local
/// to this module so the terminal does not depend on SettingsStore.
public struct TerminalTheme: Identifiable, Equatable, Sendable {
	public let id: String
	public let name: String
	/// `#rrggbb`.
	public let background: String
	public let foreground: String
	public let cursor: String
	/// 16 ANSI colors (`#rrggbb`).
	public let ansi: [String]

	public init(name: String, background: String, foreground: String, cursor: String, ansi: [String]) {
		self.id = name
		self.name = name
		self.background = background
		self.foreground = foreground
		self.cursor = cursor
		self.ansi = ansi
	}

	public static let presets: [TerminalTheme] = [
		TerminalTheme(
			name: "Caterm Dark",
			background: "#000000", foreground: "#e6e6e6", cursor: "#33ff66",
			ansi: ["#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
			       "#666666", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea"]),
		TerminalTheme(
			name: "Solarized Dark",
			background: "#002b36", foreground: "#839496", cursor: "#93a1a1",
			ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
			       "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
		TerminalTheme(
			name: "Nord",
			background: "#2e3440", foreground: "#d8dee9", cursor: "#88c0d0",
			ansi: ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
			       "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"]),
		TerminalTheme(
			name: "Dracula",
			background: "#282a36", foreground: "#f8f8f2", cursor: "#ff79c6",
			ansi: ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
			       "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"]),
		TerminalTheme(
			name: "Light",
			background: "#ffffff", foreground: "#1a1a1a", cursor: "#0066cc",
			ansi: ["#000000", "#c91b00", "#00c200", "#c7c400", "#0225c7", "#ca30c7", "#00c5c7", "#c7c7c7",
			       "#686868", "#ff6e67", "#5ffa68", "#fffc67", "#6871ff", "#ff77ff", "#60fdff", "#ffffff"]),
	]
}
