import XCTest
@testable import SSHCommandBuilder

/// These tests are the credential security perimeter. Any failure here means
/// user input can break out of single-quote shell context and execute
/// arbitrary code via libghostty's bash invocation. Treat any regression as a
/// security incident.
final class FuzzInjectionTests: XCTestCase {
    let evilStrings: [String] = [
        "'; rm -rf / ;'",
        "$(rm -rf /)",
        "`whoami`",
        "a;b",
        "a\"b",
        "a\\b",
        "a\nb",
        "a\tb",
        "a\\\\b",
        "a$b",
        "a$(b)",
        "a`b`",
        "a|b",
        "a&b",
        "a>b",
        "a<b",
        "café é",
        "中文 测试",
        "emoji 😀 here",
        "spaces  spaces",
        "'''''",
    ]

    func testEvilHostnameDoesNotEscapeQuotes() {
        for evil in evilStrings {
            let host = Host(id: UUID(), name: "x", hostname: evil, port: 22,
                            username: "u", credential: .password)
            let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                                 knownHostsCaterm: "/A", knownHostsUser: "/B")
            assertWellFormedSingleQuoting(result.command,
                                          message: "hostname=\(evil.debugDescription)")
        }
    }

    func testEvilUsernameDoesNotEscapeQuotes() {
        for evil in evilStrings {
            let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                            username: evil, credential: .password)
            let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                                 knownHostsCaterm: "/A", knownHostsUser: "/B")
            assertWellFormedSingleQuoting(result.command,
                                          message: "username=\(evil.debugDescription)")
        }
    }

    func testEvilKeyPathDoesNotEscapeQuotes() {
        for evil in evilStrings {
            let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                            username: "u",
                            credential: .keyFile(keyPath: evil, hasPassphrase: false))
            let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                                 knownHostsCaterm: "/A", knownHostsUser: "/B")
            assertWellFormedSingleQuoting(result.command,
                                          message: "keyPath=\(evil.debugDescription)")
        }
    }

    /// Walk the string, count single-quote runs. We assert: (a) the string
    /// contains balanced single-quote regions, (b) outside quoted regions
    /// only ssh's own structure characters appear. The POSIX `'\''` idiom for
    /// embedding a single quote inside a quoted region is recognized: after a
    /// closing `'`, a `\'` two-char escape (literal `'` outside quotes) is
    /// consumed without affecting quote state.
    private func assertWellFormedSingleQuoting(_ cmd: String, message: String) {
        var inQuote = false
        var i = cmd.startIndex
        while i < cmd.endIndex {
            let c = cmd[i]
            if c == "'" {
                inQuote.toggle()
                i = cmd.index(after: i)
                continue
            }
            if !inQuote {
                // Recognize `\'` POSIX escape sequence outside quotes (used by
                // the `'\''` idiom). Consume both chars; quote state unchanged.
                if c == "\\" {
                    let next = cmd.index(after: i)
                    if next < cmd.endIndex && cmd[next] == "'" {
                        i = cmd.index(after: next)
                        continue
                    }
                    XCTFail("Stray '\\' outside quoted region in \(cmd) — \(message)")
                    return
                }
                // Outside quotes, only ssh's own structure chars allowed:
                // letters/digits, `-`, `=`, `/`, `_`, `.`, `@`, ` `, `:`.
                let allowed: Set<Character> = ["-", "=", "/", "_", ".", "@", " ", ":"]
                if !c.isLetter && !c.isNumber && !allowed.contains(c) {
                    XCTFail("Stray '\(c)' outside quoted region in \(cmd) — \(message)")
                    return
                }
            }
            i = cmd.index(after: i)
        }
        XCTAssertFalse(inQuote, "Unbalanced single quotes in \(cmd) — \(message)")
    }
}
