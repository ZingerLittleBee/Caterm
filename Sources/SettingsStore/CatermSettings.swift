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
	public var prefersNativeMobileKeyboard: Bool?
	public var unknownFields: [String: SettingsOpaqueValue]

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
		theme: String? = nil,
		prefersNativeMobileKeyboard: Bool? = nil,
		unknownFields: [String: SettingsOpaqueValue] = [:]
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
		self.prefersNativeMobileKeyboard = prefersNativeMobileKeyboard
		self.unknownFields = unknownFields
    }

	private static let knownKeys: Set<String> = [
		"fontFamily", "fontSize", "lineHeight", "cursorStyle", "cursorBlink",
		"bell", "scrollbackBytes", "windowOpacity", "windowPaddingX",
		"windowPaddingY", "titlebarStyle", "theme",
		"prefersNativeMobileKeyboard",
	]

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: SettingsCodingKey.self)
		func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
			try container.decodeIfPresent(type, forKey: SettingsCodingKey(key))
		}
		fontFamily = try decode(String.self, "fontFamily")
		fontSize = try decode(Int.self, "fontSize")
		lineHeight = try decode(Double.self, "lineHeight")
		cursorStyle = try decode(CursorStyle.self, "cursorStyle")
		cursorBlink = try decode(Bool.self, "cursorBlink")
		bell = try decode(BellMode.self, "bell")
		scrollbackBytes = try decode(Int.self, "scrollbackBytes")
		windowOpacity = try decode(Double.self, "windowOpacity")
		windowPaddingX = try decode(Int.self, "windowPaddingX")
		windowPaddingY = try decode(Int.self, "windowPaddingY")
		titlebarStyle = try decode(TitlebarStyle.self, "titlebarStyle")
		theme = try decode(String.self, "theme")
		prefersNativeMobileKeyboard = try decode(
			Bool.self,
			"prefersNativeMobileKeyboard"
		)
		unknownFields = try Dictionary(uniqueKeysWithValues: container.allKeys
			.filter { !Self.knownKeys.contains($0.stringValue) }
			.map { key in
				(key.stringValue, try container.decode(
					SettingsOpaqueValue.self,
					forKey: key
				))
			})
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: SettingsCodingKey.self)
		func encode<T: Encodable>(_ value: T?, _ key: String) throws {
			try container.encodeIfPresent(value, forKey: SettingsCodingKey(key))
		}
		try encode(fontFamily, "fontFamily")
		try encode(fontSize, "fontSize")
		try encode(lineHeight, "lineHeight")
		try encode(cursorStyle, "cursorStyle")
		try encode(cursorBlink, "cursorBlink")
		try encode(bell, "bell")
		try encode(scrollbackBytes, "scrollbackBytes")
		try encode(windowOpacity, "windowOpacity")
		try encode(windowPaddingX, "windowPaddingX")
		try encode(windowPaddingY, "windowPaddingY")
		try encode(titlebarStyle, "titlebarStyle")
		try encode(theme, "theme")
		try encode(prefersNativeMobileKeyboard, "prefersNativeMobileKeyboard")
		for (key, value) in unknownFields where !Self.knownKeys.contains(key) {
			try container.encode(value, forKey: SettingsCodingKey(key))
		}
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
	public var unknownFields: [String: SettingsOpaqueValue]

    public init(
        version: Int = 2,
        revision: String = "",
        global: PartialSettings = PartialSettings(),
        hostOverrides: [HostId: PartialSettings] = [:],
        migrationsCompleted: Set<String> = [],
        seedVersion: Int = 0,
        seededByDefault: Bool = false,
        firstUserEditedAt: Date? = nil,
		canonicalSeedHash: String = "",
		unknownFields: [String: SettingsOpaqueValue] = [:]
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
		self.unknownFields = unknownFields
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
	private static let knownKeys: Set<String> = [
		"version", "revision", "global", "hostOverrides", "migrationsCompleted",
		"seedVersion", "seededByDefault", "firstUserEditedAt",
		"canonicalSeedHash",
	]

	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: SettingsCodingKey.self)
		func key(_ value: String) -> SettingsCodingKey { SettingsCodingKey(value) }
        // Absent = legacy v1 plist written before this field existed.
        // Do NOT bump this sentinel when adding v3; gate via a separate check.
		self.version = try c.decodeIfPresent(Int.self, forKey: key("version")) ?? 1
		self.revision = try c.decodeIfPresent(String.self, forKey: key("revision")) ?? ""
		self.global = try c.decodeIfPresent(
			PartialSettings.self,
			forKey: key("global")
		) ?? PartialSettings()
		self.hostOverrides = try c.decodeIfPresent(
			[HostId: PartialSettings].self,
			forKey: key("hostOverrides")
		) ?? [:]
		self.migrationsCompleted = try c.decodeIfPresent(
			Set<String>.self,
			forKey: key("migrationsCompleted")
		) ?? []
		self.seedVersion = try c.decodeIfPresent(
			Int.self,
			forKey: key("seedVersion")
		) ?? 0
		self.seededByDefault = try c.decodeIfPresent(
			Bool.self,
			forKey: key("seededByDefault")
		) ?? false
		self.firstUserEditedAt = try c.decodeIfPresent(
			Date.self,
			forKey: key("firstUserEditedAt")
		)
		self.canonicalSeedHash = try c.decodeIfPresent(
			String.self,
			forKey: key("canonicalSeedHash")
		) ?? ""
		self.unknownFields = try Dictionary(uniqueKeysWithValues: c.allKeys
			.filter { !Self.knownKeys.contains($0.stringValue) }
			.map { codingKey in
				(codingKey.stringValue, try c.decode(
					SettingsOpaqueValue.self,
					forKey: codingKey
				))
			})
    }

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: SettingsCodingKey.self)
		func key(_ value: String) -> SettingsCodingKey { SettingsCodingKey(value) }
		try container.encode(version, forKey: key("version"))
		try container.encode(revision, forKey: key("revision"))
		try container.encode(global, forKey: key("global"))
		try container.encode(hostOverrides, forKey: key("hostOverrides"))
		try container.encode(migrationsCompleted, forKey: key("migrationsCompleted"))
		try container.encode(seedVersion, forKey: key("seedVersion"))
		try container.encode(seededByDefault, forKey: key("seededByDefault"))
		try container.encodeIfPresent(firstUserEditedAt, forKey: key("firstUserEditedAt"))
		try container.encode(canonicalSeedHash, forKey: key("canonicalSeedHash"))
		for (field, value) in unknownFields where !Self.knownKeys.contains(field) {
			try container.encode(value, forKey: key(field))
		}
	}
}
