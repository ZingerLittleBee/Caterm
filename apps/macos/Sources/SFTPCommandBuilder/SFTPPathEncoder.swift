import Foundation

public enum SFTPPathEncodingError: Error, Equatable {
    case empty
    case containsControlChar(Character)
    case containsGlob(Character)
    case pathTooLong(bytes: Int)
    case leadingDashUnnormalized
}

public enum SFTPPathEncoder {
    public static func encode(_ path: String) throws -> String {
        if path.isEmpty { throw SFTPPathEncodingError.empty }
        let bytes = path.utf8.count
        if bytes > 1023 { throw SFTPPathEncodingError.pathTooLong(bytes: bytes) }
        if path.first == "-" { throw SFTPPathEncodingError.leadingDashUnnormalized }
        for ch in path {
            if let scalar = ch.unicodeScalars.first?.value {
                if scalar < 0x20 || scalar == 0x7F {
                    throw SFTPPathEncodingError.containsControlChar(ch)
                }
            }
            if ch == "*" || ch == "?" || ch == "[" {
                throw SFTPPathEncodingError.containsGlob(ch)
            }
        }
        var escaped = ""
        escaped.reserveCapacity(path.count + 4)
        for ch in path {
            if ch == "\\" { escaped.append("\\\\") }
            else if ch == "\"" { escaped.append("\\\"") }
            else { escaped.append(ch) }
        }
        return "\"\(escaped)\""
    }

    /// Encode a *remote* path for `sftp` batch-mode commands. Differs from
    /// `encode` only in tilde handling: sftp expands `~` and `~/foo` to the
    /// remote home directory, but **only when unquoted**. `cd "~"` is a literal
    /// directory named `~` and fails. We emit the tilde unquoted and quote the
    /// rest by concatenation (`~/"name with space"` is valid sftp syntax).
    public static func encodeRemote(_ path: String) throws -> String {
        if path.isEmpty { throw SFTPPathEncodingError.empty }
        if path == "~" { return "~" }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            if rest.isEmpty { return "~" }
            return "~/" + (try encode(rest))
        }
        return try encode(path)
    }
}
