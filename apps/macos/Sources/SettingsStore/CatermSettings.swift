import Foundation

public struct HostId: Codable, Hashable, RawRepresentable {
    public let rawValue: String
    public init(_ raw: String) { self.rawValue = raw }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum CursorStyle: String, Codable, CaseIterable, Equatable {
    case block, bar, underline
}

public enum BellMode: String, Codable, CaseIterable, Equatable {
    case none, audio, visual, both
}

public enum TitlebarStyle: String, Codable, CaseIterable, Equatable {
    case tabs, transparent, native, hidden
}

public struct PartialSettings: Codable, Equatable {
    public var fontFamily: String?
    public var fontSize: Int?
    public var lineHeight: Double?
    public var cursorStyle: CursorStyle?
    public var cursorBlink: Bool?
    public var bell: BellMode?
    public var scrollbackBytes: Int?
    public var windowOpacity: Double?
    public var windowPaddingX: Int?
    public var windowPaddingY: Int?
    public var titlebarStyle: TitlebarStyle?
    public var theme: String?

    public init(
        fontFamily: String? = nil,
        fontSize: Int? = nil,
        lineHeight: Double? = nil,
        cursorStyle: CursorStyle? = nil,
        cursorBlink: Bool? = nil,
        bell: BellMode? = nil,
        scrollbackBytes: Int? = nil,
        windowOpacity: Double? = nil,
        windowPaddingX: Int? = nil,
        windowPaddingY: Int? = nil,
        titlebarStyle: TitlebarStyle? = nil,
        theme: String? = nil
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.bell = bell
        self.scrollbackBytes = scrollbackBytes
        self.windowOpacity = windowOpacity
        self.windowPaddingX = windowPaddingX
        self.windowPaddingY = windowPaddingY
        self.titlebarStyle = titlebarStyle
        self.theme = theme
    }
}

public struct CatermSettings: Codable, Equatable {
    public var version: Int
    public var revision: String
    public var global: PartialSettings
    public var hostOverrides: [HostId: PartialSettings]
    public var migrationsCompleted: Set<String>

    public init(
        version: Int = 1,
        revision: String = "",
        global: PartialSettings = PartialSettings(),
        hostOverrides: [HostId: PartialSettings] = [:],
        migrationsCompleted: Set<String> = []
    ) {
        self.version = version
        self.revision = revision
        self.global = global
        self.hostOverrides = hostOverrides
        self.migrationsCompleted = migrationsCompleted
    }

    public static let empty = CatermSettings()

    public static let defaultsSeed: PartialSettings = PartialSettings(
        fontFamily: "SF Mono",
        fontSize: 13,
        cursorStyle: .block,
        scrollbackBytes: 10_000_000,
        titlebarStyle: .tabs,
        theme: "Catppuccin Mocha"
    )
}
