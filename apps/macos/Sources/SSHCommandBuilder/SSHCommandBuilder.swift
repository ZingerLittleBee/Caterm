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

	/// Production entry point. Production callers route through this; the
	/// internal `_build` exposes test seams (`sshPath:`, `terminfoDump:`).
	public static func build(
		host: Host,
		askpassPath: String,
		knownHostsCaterm: String,
		knownHostsUser: String,
		installTerminfo: Bool = false
	) -> Output {
		_build(
			host: host,
			askpassPath: askpassPath,
			knownHostsCaterm: knownHostsCaterm,
			knownHostsUser: knownHostsUser,
			installTerminfo: installTerminfo,
			sshPath: "/usr/bin/ssh",
			terminfoDump: TerminfoSource.terminfoDump()
		)
	}

	/// Test seam. Reachable via `@testable import SSHCommandBuilder`.
	/// `sshPath` substitutes the executable Caterm spawns — production passes
	/// `/usr/bin/ssh`. When `sshPath == "/usr/bin/ssh"` we emit it as `.raw` so
	/// the byte-for-byte v1.5 regression baseline is preserved; otherwise we
	/// quote it (defensive against temp paths with spaces in unusual CI envs).
	/// `terminfoDump: nil` exercises the bundle-missing fallback.
	static func _build(
		host: Host,
		askpassPath: String,
		knownHostsCaterm: String,
		knownHostsUser: String,
		installTerminfo: Bool,
		sshPath: String,
		terminfoDump: String?
	) -> Output {
		let sshArg: Arg = sshPath == "/usr/bin/ssh" ? .raw(sshPath) : .quoted(sshPath)
		var args: [Arg] = [sshArg]

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

		// Decide whether to install terminfo. When the toggle is on but the
		// bundle is missing, degrade to toggle-off-equivalent shape — no `-t`,
		// no env override — so we never advertise xterm-ghostty without a
		// backing terminfo on the remote (see spec §5.2 / §6 row #6).
		let willInstall = installTerminfo && terminfoDump != nil

		if willInstall {
			args += [.raw("-t")]
		}

		// user@host with each side quoted, '@' literal between.
		let userHost = "\(ShellQuote.posix(host.username))@\(ShellQuote.posix(host.hostname))"
		args.append(.verbatim(userHost))

		if willInstall, let dump = terminfoDump {
			let wrapper = """
			if ! infocmp xterm-ghostty >/dev/null 2>&1; then
			  if command -v tic >/dev/null 2>&1; then
			    tic -x - <<'TERMINFO_EOF'
			\(dump)
			TERMINFO_EOF
			    [ $? -ne 0 ] && export TERM=xterm-256color
			  else
			    export TERM=xterm-256color
			  fi
			fi
			exec "${SHELL:-/bin/sh}" -l
			"""
			args.append(.quoted(wrapper))
			env.append(("TERM", "xterm-ghostty"))
		}

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
