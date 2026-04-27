import Foundation

public enum SSHCommandBuilder {
    public struct Output: Equatable {
        public let command: String
        public let env: [(String, String)]

        public static func == (lhs: Output, rhs: Output) -> Bool {
            lhs.command == rhs.command &&
                lhs.env.map { [$0.0, $0.1] } == rhs.env.map { [$0.0, $0.1] }
        }
    }

    /// One argument piece; either emitted raw (for ssh's own flags / constant
    /// paths / numeric values) or single-quoted (for everything user-derived).
    private enum Arg {
        case raw(String)
        case quoted(String)
        /// Pre-built composite (e.g. `'user'@'host'`) inserted verbatim.
        case verbatim(String)
    }

    public static func build(
        host: Host,
        askpassPath: String,
        knownHostsCaterm: String,
        knownHostsUser: String
    ) -> Output {
        var args: [Arg] = [.raw("/usr/bin/ssh")]

        let knownHostsValue = "\(knownHostsCaterm) \(knownHostsUser)"

        args += [.raw("-o"), .quoted("StrictHostKeyChecking=accept-new")]
        args += [.raw("-o"), .quoted("UserKnownHostsFile=\(knownHostsValue)")]

        var env: [(String, String)] = []

        switch host.credential {
        case .password:
            args += [.raw("-o"), .quoted("PreferredAuthentications=password")]
            args += [.raw("-o"), .quoted("PubkeyAuthentication=no")]
            args += [.raw("-o"), .quoted("KbdInteractiveAuthentication=no")]
            args += [.raw("-o"), .quoted("NumberOfPasswordPrompts=1")]
            env = [
                ("SSH_ASKPASS", askpassPath),
                ("SSH_ASKPASS_REQUIRE", "force"),
                ("CATERM_HOST_ID", host.id.uuidString),
                ("CATERM_ASKPASS_KIND", "password"),
            ]

        case let .keyFile(keyPath, hasPassphrase):
            args += [.raw("-o"), .quoted("IdentitiesOnly=yes")]
            args += [.raw("-o"), .quoted("PreferredAuthentications=publickey")]
            args += [.raw("-o"), .quoted("PasswordAuthentication=no")]
            args += [.raw("-o"), .quoted("KbdInteractiveAuthentication=no")]
            args += [.raw("-i"), .quoted(keyPath)]
            if hasPassphrase {
                env = [
                    ("SSH_ASKPASS", askpassPath),
                    ("SSH_ASKPASS_REQUIRE", "force"),
                    ("CATERM_HOST_ID", host.id.uuidString),
                    ("CATERM_ASKPASS_KIND", "passphrase"),
                ]
            }

        case .agent:
            args += [.raw("-o"), .quoted("BatchMode=yes")]
        }

        args += [.raw("-p"), .raw(String(host.port))]

        // user@host with each side quoted, '@' literal between.
        let userHost = "\(ShellQuote.posix(host.username))@\(ShellQuote.posix(host.hostname))"
        args.append(.verbatim(userHost))

        let cmd = args.map { arg -> String in
            switch arg {
            case let .raw(s): return s
            case let .quoted(s): return ShellQuote.posix(s)
            case let .verbatim(s): return s
            }
        }.joined(separator: " ")

        return Output(command: cmd, env: env)
    }
}
