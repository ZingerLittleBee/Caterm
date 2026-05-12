import Foundation

public enum SSHCommandBuilder {
	public struct Output: Equatable {
		public let command: String
		public let env: [(String, String)]
		public let configURL: URL?

		public init(command: String, env: [(String, String)],
		            configURL: URL? = nil) {
			self.command = command
			self.env = env
			self.configURL = configURL
		}

		public static func == (lhs: Output, rhs: Output) -> Bool {
			lhs.command == rhs.command &&
				lhs.env.map { [$0.0, $0.1] } == rhs.env.map { [$0.0, $0.1] } &&
				lhs.configURL == rhs.configURL
		}
	}

	// MARK: - Per-host options helper (T9 — consumed by T10)

	/// All per-host SSH options, ready for T10 to emit into either a
	/// direct-path command or a ProxyJump/ProxyCommand chain leg.
	internal struct PerHostOptions {
		/// Raw hostname — quoting applied by the emitter (SSHConfigQuote or ShellQuote).
		let hostName: String
		let port: Int
		/// Raw username — quoting applied by the emitter.
		let user: String
		/// Raw key-file path; nil for password / agent credentials.
		let identityFile: String?
		/// Each entry is "<key> <value>" with the value already encoded via
		/// SSHConfigQuote.encode, ready for insertion into an ssh_config block.
		let optionLines: [String]
		/// Per-host environment variables (SSH_ASKPASS, CATERM_HOST_ID, …).
		/// Only populated for the target host; jump hosts do not need askpass.
		let env: [(String, String)]
	}

	/// Produce the per-host SSH options for one hop in a connection chain.
	///
	/// - Parameters:
	///   - host: The SSH host whose options to build.
	///   - isTarget: `true` for the final target; `false` for jump hosts.
	///               Only the target host gets `SSH_ASKPASS` / credential env vars.
	///   - askpassPath: Absolute path to the caterm-askpass helper binary.
	///   - knownHostsCaterm: Absolute path to Caterm's own known_hosts file.
	///   - knownHostsUser: Absolute path to the user's known_hosts file.
	///   - accessGroup: Keychain access group (set by SessionStore, not here).
	///
	/// This function is **dead code** until T10 wires it. `build()` is unchanged.
	internal static func perHostOptions(
		for host: SSHHost,
		isTarget: Bool,
		askpassPath: String,
		knownHostsCaterm: String,
		knownHostsUser: String,
		accessGroup: String?
	) throws -> PerHostOptions {
		var lines: [String] = []
		var env: [(String, String)] = []

		// Always-present connection options.
		lines.append("StrictHostKeyChecking accept-new")
		let knownHostsValue = "\(knownHostsCaterm) \(knownHostsUser)"
		lines.append("UserKnownHostsFile \(try SSHConfigQuote.encode(knownHostsValue))")
		lines.append("ControlMaster auto")
		lines.append("ControlPersist 10m")
		let controlPath = "~/Library/Caches/Caterm/cm/\(host.id.uuidString).sock"
		lines.append("ControlPath \(try SSHConfigQuote.encode(controlPath))")

		// Per-credential options.
		var identityFile: String?
		switch host.credential {
		case .password:
			lines.append("PreferredAuthentications password,keyboard-interactive")
			lines.append("PubkeyAuthentication no")
			lines.append("NumberOfPasswordPrompts 1")
			if isTarget {
				env = [
					("SSH_ASKPASS", askpassPath),
					("SSH_ASKPASS_REQUIRE", "force"),
					("CATERM_HOST_ID", host.id.uuidString),
					("CATERM_ASKPASS_KIND", "password"),
				]
			}

		case let .keyFile(keyPath, hasPassphrase):
			lines.append("IdentitiesOnly yes")
			lines.append("PreferredAuthentications publickey")
			lines.append("PasswordAuthentication no")
			lines.append("KbdInteractiveAuthentication no")
			lines.append("IdentityFile \(try SSHConfigQuote.encode(keyPath))")
			identityFile = keyPath
			if hasPassphrase, isTarget {
				env = [
					("SSH_ASKPASS", askpassPath),
					("SSH_ASKPASS_REQUIRE", "force"),
					("CATERM_HOST_ID", host.id.uuidString),
					("CATERM_ASKPASS_KIND", "keyPassphrase"),
				]
			}

		case .agent:
			lines.append("BatchMode yes")
		}

		_ = accessGroup  // CATERM_ACCESS_GROUP is set by SessionStore, not here.

		// Forwards: target only. OpenSSH's ExitOnForwardFailure is a global
		// option; we enable it solely when every forward is required so
		// optional forwards don't take down the connection on bind failure.
		// (See spec §"Known Limitations" for the mixed-required-and-optional
		// remote-bind silent-failure caveat.)
		if isTarget, !host.forwards.isEmpty {
			var anyOptional = false
			for fwd in host.forwards {
				lines.append(try fwd.sshConfigLine())
				if !fwd.required { anyOptional = true }
			}
			if !anyOptional {
				lines.append("ExitOnForwardFailure yes")
			}
		}

		return PerHostOptions(
			hostName: host.hostname,
			port: host.port,
			user: host.username,
			identityFile: identityFile,
			optionLines: lines,
			env: env
		)
	}

	// MARK: - Command argument model

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

		let controlPath = "~/Library/Caches/Caterm/cm/\(host.id.uuidString).sock"
		args += [.raw("-o"), .quoted("ControlMaster=auto")]
		args += [.raw("-o"), .quoted("ControlPersist=10m")]
		args += [.raw("-o"), .quoted("ControlPath=\(controlPath)")]

		var env: [(String, String)] = []

		switch host.credential {
		case .password:
			// Many OpenSSH servers route password logins through `keyboard-interactive`
			// rather than the bare `password` method, so we offer both. With
			// SSH_ASKPASS_REQUIRE=force (set below), OpenSSH 8.4+ routes
			// keyboard-interactive prompts through askpass too.
			args += [.raw("-o"), .quoted("PreferredAuthentications=password,keyboard-interactive")]
			args += [.raw("-o"), .quoted("PubkeyAuthentication=no")]
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
					("CATERM_ASKPASS_KIND", "keyPassphrase"),
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
			    tic -x - 2>/dev/null <<'TERMINFO_EOF'
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

	// MARK: - Chain-aware build (T10)

	/// Entry point for chain-aware connections. When `ancestors` is empty,
	/// delegates to the direct path and returns byte-identical output.
	/// When `ancestors` is non-empty, writes a per-session ssh_config snippet
	/// via `configSink` and returns an `Output` whose `configURL` identifies
	/// the written file for later cleanup.
	///
	/// `terminfoDump` is an optional test seam. When `nil` (the default),
	/// the bundled resource is resolved via `TerminfoSource` — matching the
	/// behaviour of the direct-path `build(host:askpassPath:…)` overload.
	/// Pass a non-nil string (including an empty string sentinel) explicitly
	/// in tests to control what dump content is used.
	public static func build(
		host: SSHHost,
		ancestors: [SSHHost] = [],
		configSink: SSHConfigSink,
		askpassPath: String,
		knownHostsCaterm: String,
		knownHostsUser: String,
		installTerminfo: Bool = false,
		sshPath: String = "/usr/bin/ssh",
		terminfoDump: String? = nil
	) throws -> Output {
		// Resolve the terminfo dump from the bundle when not supplied by the
		// caller. This mirrors the direct-path build overload which always
		// calls TerminfoSource.terminfoDump() internally.
		let resolvedDump: String? = terminfoDump ?? TerminfoSource.terminfoDump()
		if ancestors.isEmpty {
			return _build(
				host: host,
				askpassPath: askpassPath,
				knownHostsCaterm: knownHostsCaterm,
				knownHostsUser: knownHostsUser,
				installTerminfo: installTerminfo,
				sshPath: sshPath,
				terminfoDump: resolvedDump
			)
		}
		return try buildChain(
			target: host,
			ancestors: ancestors,
			configSink: configSink,
			askpassPath: askpassPath,
			knownHostsCaterm: knownHostsCaterm,
			knownHostsUser: knownHostsUser,
			installTerminfo: installTerminfo,
			sshPath: sshPath,
			terminfoDump: resolvedDump
		)
	}

	/// Builds a multi-hop connection by writing a per-session ssh_config
	/// with one `Host caterm-h-<uuid>` block per hop and ProxyJump linking
	/// each hop to the previous one. Returns `configURL` set to the written
	/// file URL for later cleanup.
	private static func buildChain(
		target: SSHHost,
		ancestors: [SSHHost],
		configSink: SSHConfigSink,
		askpassPath: String,
		knownHostsCaterm: String,
		knownHostsUser: String,
		installTerminfo: Bool,
		sshPath: String,
		terminfoDump: String?
	) throws -> Output {
		// Full hop list in dial order: [deepest ancestor … target]
		let hops: [SSHHost] = ancestors + [target]

		// Build one Host block per hop. May throw SSHConfigQuoteError if
		// any hostname / value contains a control character.
		var blocks: [String] = []
		for (index, hop) in hops.enumerated() {
			let alias = "caterm-h-\(hop.id.uuidString)"
			let opts = try perHostOptions(
				for: hop,
				isTarget: hop.id == target.id,
				askpassPath: askpassPath,
				knownHostsCaterm: knownHostsCaterm,
				knownHostsUser: knownHostsUser,
				accessGroup: nil
			)

			var lines: [String] = ["Host \(alias)"]
			lines.append("\tHostName \(try SSHConfigQuote.encode(opts.hostName))")
			lines.append("\tPort \(opts.port)")
			lines.append("\tUser \(try SSHConfigQuote.encode(opts.user))")

			// ProxyJump: every hop except the deepest (index 0) points at
			// the previous hop's alias.
			if index > 0 {
				let prevAlias = "caterm-h-\(hops[index - 1].id.uuidString)"
				lines.append("\tProxyJump \(prevAlias)")
			}

			for line in opts.optionLines {
				lines.append("\t\(line)")
			}

			blocks.append(lines.joined(separator: "\n"))
		}

		let configContent = blocks.joined(separator: "\n\n") + "\n"
		let configURL = try configSink.write(configContent)

		// Build target env from perHostOptions (contains askpass, CATERM_HOST_ID…)
		let targetOpts = try perHostOptions(
			for: target,
			isTarget: true,
			askpassPath: askpassPath,
			knownHostsCaterm: knownHostsCaterm,
			knownHostsUser: knownHostsUser,
			accessGroup: nil
		)
		var env: [(String, String)] = targetOpts.env

		// Build CATERM_CHAIN JSON array — one entry per hop.
		var chainEntries: [[String: Any]] = []
		for hop in hops {
			let alias = "caterm-h-\(hop.id.uuidString)"
			var entry: [String: Any] = [
				"alias": alias,
				"hostId": hop.id.uuidString,
				"user": hop.username,
				"hostname": hop.hostname,
				"port": hop.port,
			]
			if case let .keyFile(keyPath, _) = hop.credential {
				entry["keyPath"] = keyPath
			}
			chainEntries.append(entry)
		}
		let chainData = try JSONSerialization.data(withJSONObject: chainEntries, options: [.sortedKeys])
		let chainJSON = String(data: chainData, encoding: .utf8) ?? "[]"
		env.append(("CATERM_CHAIN", chainJSON))

		// Assemble the final command: ssh -F <configPath> caterm-h-<target-uuid>
		let targetAlias = "caterm-h-\(target.id.uuidString)"
		let sshArg: String = sshPath == "/usr/bin/ssh" ? sshPath : ShellQuote.posix(sshPath)
		let configPathArg = ShellQuote.posix(configURL.path)

		let willInstall = installTerminfo && terminfoDump != nil

		var cmdParts: [String] = [sshArg, "-F", configPathArg]
		if willInstall {
			cmdParts.append("-t")
		}
		cmdParts.append(targetAlias)

		if willInstall, let dump = terminfoDump {
			let wrapper = """
			if ! infocmp xterm-ghostty >/dev/null 2>&1; then
			  if command -v tic >/dev/null 2>&1; then
			    tic -x - 2>/dev/null <<'TERMINFO_EOF'
			\(dump)
			TERMINFO_EOF
			    [ $? -ne 0 ] && export TERM=xterm-256color
			  else
			    export TERM=xterm-256color
			  fi
			fi
			exec "${SHELL:-/bin/sh}" -l
			"""
			cmdParts.append(ShellQuote.posix(wrapper))
			env.append(("TERM", "xterm-ghostty"))
		}

		let cmd = cmdParts.joined(separator: " ")
		return Output(command: cmd, env: env, configURL: configURL)
	}
}
