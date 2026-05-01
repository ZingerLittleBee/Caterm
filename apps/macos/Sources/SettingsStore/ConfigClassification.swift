import Foundation

public struct RepresentableEntry: Equatable {
    public let key: String
    public let value: PartialFieldValue
    public let sourceLines: [Int]
}

public enum PartialFieldValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case cursorStyle(CursorStyle)
    case bell(BellMode)
    case titlebar(TitlebarStyle)
}

public struct UnrepresentableEntry: Equatable {
    public let key: String
    public let sourceLines: [Int]
    public let reason: Reason

    public enum Reason: Equatable {
        case fallbackChain(count: Int)
        case lightDarkSplit
        case customBellFeatures(rendered: String)
        case unmodeledKey(key: String)
        case unparseableValue
    }
}

public struct ConfigClassification: Equatable {
    public var representable: [RepresentableEntry]
    public var unrepresentable: [UnrepresentableEntry]
}

public extension PartialSettings {
    static let unmodeledTrackedKeys: Set<String> = [
        "palette", "theme-light", "theme-dark", "background-image",
        "keybind", "command-palette-entry",
    ]

    static let multiOccurrenceFallbackKeys: Set<String> = [
        "font-family",
    ]

    static func classifyConfig(_ text: String) -> ConfigClassification {
        let entries = GhosttyConfigParser.parse(text)
        var groups: [String: [ConfigEntry]] = [:]
        for e in entries { groups[e.key.lowercased(), default: []].append(e) }

        var rep: [RepresentableEntry] = []
        var unrep: [UnrepresentableEntry] = []

        for (key, group) in groups.sorted(by: { $0.key < $1.key }) {
            let lines = group.map(\.sourceLine)

            if unmodeledTrackedKeys.contains(key) {
                unrep.append(.init(key: key, sourceLines: lines,
                                    reason: .unmodeledKey(key: key)))
                continue
            }

            if multiOccurrenceFallbackKeys.contains(key), group.count > 1 {
                unrep.append(.init(key: key, sourceLines: lines,
                                    reason: .fallbackChain(count: group.count)))
                continue
            }

            if group.count > 1 {
                // Multi-occurrence on a key that doesn't model fallback: treat as unmodeled
                unrep.append(.init(key: key, sourceLines: lines,
                                    reason: .unmodeledKey(key: key)))
                continue
            }

            let entry = group[0]
            switch classifySingle(key: key, rawValue: entry.rawValue) {
            case .representable(let value):
                rep.append(.init(key: key, value: value, sourceLines: [entry.sourceLine]))
            case .unrepresentable(let reason):
                unrep.append(.init(key: key, sourceLines: [entry.sourceLine], reason: reason))
            case .ignored:
                continue
            }
        }
        return ConfigClassification(representable: rep, unrepresentable: unrep)
    }

    private enum SingleClassification {
        case representable(PartialFieldValue)
        case unrepresentable(UnrepresentableEntry.Reason)
        case ignored
    }

    private static func classifySingle(key: String, rawValue: String) -> SingleClassification {
        switch key {
        case "font-family": return .representable(.string(rawValue))
        case "font-size":
            if let i = Int(rawValue) { return .representable(.int(i)) }
            return .unrepresentable(.unparseableValue)
        case "theme":
            if rawValue.contains("light:") || rawValue.contains("dark:") {
                return .unrepresentable(.lightDarkSplit)
            }
            return .representable(.string(rawValue))
        case "cursor-style":
            if let v = CursorStyle(rawValue: rawValue) { return .representable(.cursorStyle(v)) }
            return .unrepresentable(.unparseableValue)
        case "cursor-style-blink":
            if let b = Bool(rawValue) { return .representable(.bool(b)) }
            return .unrepresentable(.unparseableValue)
        case "bell-features":
            if let mode = canonicalBellMode(forFeatures: rawValue) {
                return .representable(.bell(mode))
            }
            return .unrepresentable(.customBellFeatures(rendered: rawValue))
        case "scrollback-limit":
            if let i = Int(rawValue) { return .representable(.int(i)) }
            return .unrepresentable(.unparseableValue)
        case "background-opacity":
            if let d = Double(rawValue) { return .representable(.double(d)) }
            return .unrepresentable(.unparseableValue)
        case "window-padding-x", "window-padding-y":
            if let i = Int(rawValue) { return .representable(.int(i)) }
            return .unrepresentable(.unparseableValue)
        case "macos-titlebar-style":
            if let v = TitlebarStyle(rawValue: rawValue) { return .representable(.titlebar(v)) }
            return .unrepresentable(.unparseableValue)
        default:
            return .ignored
        }
    }

    private static func canonicalBellMode(forFeatures features: String) -> BellMode? {
        let canonical: [String: BellMode] = [
            "no-system,no-audio,no-attention,no-title,no-border": .none,
            "no-system,audio,no-attention,no-title,no-border": .audio,
            "no-system,no-audio,attention,title,no-border": .visual,
            "no-system,audio,attention,title,no-border": .both,
        ]
        let normalized = features.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: ",")
        return canonical[normalized]
    }
}
