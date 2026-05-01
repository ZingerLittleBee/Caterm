import Foundation

public struct ConfigEntry: Equatable {
    public let key: String
    public let rawValue: String
    public let sourceLine: Int  // 1-based
    public let originalLine: String  // for lossless edit

    public init(key: String, rawValue: String, sourceLine: Int, originalLine: String) {
        self.key = key
        self.rawValue = rawValue
        self.sourceLine = sourceLine
        self.originalLine = originalLine
    }
}

public enum GhosttyConfigParser {
    public static func parse(_ text: String) -> [ConfigEntry] {
        var out: [ConfigEntry] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, raw) in lines.enumerated() {
            let lineNo = idx + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let key = raw[..<eq].trimmingCharacters(in: .whitespaces)
            var value = raw[raw.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value = String(value.dropFirst().dropLast())
            }
            out.append(ConfigEntry(
                key: String(key),
                rawValue: String(value),
                sourceLine: lineNo,
                originalLine: String(raw)
            ))
        }
        return out
    }
}
