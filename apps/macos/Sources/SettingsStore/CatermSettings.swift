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

    // v2 fields. Always carried in CatermSettings; SyncableSettings strips
    // migrationsCompleted before encoding to KVS but keeps these.
    public var seedVersion: Int
    public var seededByDefault: Bool
    public var firstUserEditedAt: Date?
    public var canonicalSeedHash: String

    public init(
        version: Int = 2,
        revision: String = "",
        global: PartialSettings = PartialSettings(),
        hostOverrides: [HostId: PartialSettings] = [:],
        migrationsCompleted: Set<String> = [],
        seedVersion: Int = 0,
        seededByDefault: Bool = false,
        firstUserEditedAt: Date? = nil,
        canonicalSeedHash: String = ""
    ) {
        self.version = version
        self.revision = revision
        self.global = global
        self.hostOverrides = hostOverrides
        self.migrationsCompleted = migrationsCompleted
        self.seedVersion = seedVersion
        self.seededByDefault = seededByDefault
        self.firstUserEditedAt = firstUserEditedAt
        self.canonicalSeedHash = canonicalSeedHash
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

extension CatermSettings {
    private enum CodingKeys: String, CodingKey {
        case version, revision, global, hostOverrides, migrationsCompleted
        case seedVersion, seededByDefault, firstUserEditedAt, canonicalSeedHash
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? ""
        self.global = try c.decodeIfPresent(PartialSettings.self, forKey: .global) ?? PartialSettings()
        self.hostOverrides = try c.decodeIfPresent([HostId: PartialSettings].self, forKey: .hostOverrides) ?? [:]
        self.migrationsCompleted = try c.decodeIfPresent(Set<String>.self, forKey: .migrationsCompleted) ?? []
        self.seedVersion = try c.decodeIfPresent(Int.self, forKey: .seedVersion) ?? 0
        self.seededByDefault = try c.decodeIfPresent(Bool.self, forKey: .seededByDefault) ?? false
        self.firstUserEditedAt = try c.decodeIfPresent(Date.self, forKey: .firstUserEditedAt)
        self.canonicalSeedHash = try c.decodeIfPresent(String.self, forKey: .canonicalSeedHash) ?? ""
    }
}
