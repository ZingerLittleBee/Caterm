import Foundation

public enum TerminalKeyboardMode: Equatable, Sendable {
	case custom
	case native
}

/// User-tunable defaults for new terminal sessions. The Settings screen
/// writes these through `@AppStorage`; the session models read them here
/// so a change applies to the next connection opened.
public enum MobileTerminalSettings {
	public enum Keys {
		public static let defaultThemeID = "caterm.terminal.defaultThemeID"
		public static let fontSize = "caterm.terminal.fontSize"
		public static let defaultKeyboardNative = "caterm.terminal.defaultKeyboardNative"
	}

	public static let fontSizeRange: ClosedRange<Double> = 9...24
	public static let defaultFontSize: Double = 13

	private static var store: UserDefaults { .standard }

	public static var defaultTheme: TerminalTheme {
		let id = store.string(forKey: Keys.defaultThemeID)
		return TerminalTheme.presets.first { $0.id == id } ?? TerminalTheme.presets[0]
	}

	public static var fontSize: Double {
		let raw = store.object(forKey: Keys.fontSize) as? Double ?? defaultFontSize
		return min(max(raw, fontSizeRange.lowerBound), fontSizeRange.upperBound)
	}

	public static var defaultKeyboardMode: TerminalKeyboardMode {
		store.bool(forKey: Keys.defaultKeyboardNative) ? .native : .custom
	}
}

public struct MobileTerminalPreferences: Equatable, Sendable {
	public var themeID: String
	public var fontSize: Double
	public var keyboardMode: TerminalKeyboardMode

	public init(
		themeID: String,
		fontSize: Double,
		keyboardMode: TerminalKeyboardMode
	) {
		self.themeID = themeID
		self.fontSize = min(
			max(fontSize, MobileTerminalSettings.fontSizeRange.lowerBound),
			MobileTerminalSettings.fontSizeRange.upperBound
		)
		self.keyboardMode = keyboardMode
	}

	public static var storedDefaults: MobileTerminalPreferences {
		MobileTerminalPreferences(
			themeID: MobileTerminalSettings.defaultTheme.id,
			fontSize: MobileTerminalSettings.fontSize,
			keyboardMode: MobileTerminalSettings.defaultKeyboardMode
		)
	}

	public var theme: TerminalTheme {
		TerminalTheme.presets.first { $0.id == themeID }
			?? TerminalTheme.presets[0]
	}
}
