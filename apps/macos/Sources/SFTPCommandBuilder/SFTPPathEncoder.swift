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
}
