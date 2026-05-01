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
    /// `encode` in tilde handling: tilde expansion in sftp batch mode is
    /// unreliable across versions and server configurations (OpenSSH's
    /// `internal-sftp` subsystem with no shell does not expand `~` at all).
    /// Since sftp's initial working directory is always the user's home, we
    /// strip leading `~/` and pass the rest as a relative path. A bare `~`
    /// becomes `"."` (the cwd, which is home).
    public static func encodeRemote(_ path: String) throws -> String {
        if path.isEmpty { throw SFTPPathEncodingError.empty }
        if path == "~" { return "\".\"" }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            if rest.isEmpty { return "\".\"" }
            return try encode(rest)
        }
        return try encode(path)
    }
}
