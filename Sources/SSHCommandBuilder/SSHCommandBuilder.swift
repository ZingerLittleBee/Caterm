import Foundation
import SSHCredentialContract

public enum SSHCommandBuilder {
	public struct CredentialLookup: Equatable, Sendable {
		public let service: String
		public let passwordAccount: String?
		public let passphraseAccount: String?
		public let useDataProtectionKeychain: Bool

		public init(
			service: String,
			passwordAccount: String? = nil,
			passphraseAccount: String? = nil,
			useDataProtectionKeychain: Bool
		) {
			self.service = service
			self.passwordAccount = passwordAccount
			self.passphraseAccount = passphraseAccount
			self.useDataProtectionKeychain =
				useDataProtectionKeychain
		}

		func account(for kind: SSHCredentialKind) -> String? {
			switch kind {
			case .password:
				passwordAccount
			case .keyPassphrase:
				passphraseAccount
			}
		}
	}

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

	// MARK: - Command argument model

	/// One argument piece; either emitted raw (for ssh's own flags / constant
	/// paths / numeric values) or single-quoted (for everything user-derived).
	private enum Arg {
		case raw(String)
		case quoted(String)
		/// Pre-built composite (e.g. `'user'@'host'`) inserted verbatim.
		case verbatim(String)
	}

	private struct RemoteShellBootstrap {
		let command: String
		let environment: [(String, String)]
	}

	private static func remoteShellBootstrap(
		installTerminfo: Bool,
		terminfoDump: String?
	) -> RemoteShellBootstrap? {
		guard installTerminfo, let terminfoDump else { return nil }
		let command = """
		if ! infocmp xterm-ghostty >/dev/null 2>&1; then
		  if command -v tic >/dev/null 2>&1; then
		    tic -x - 2>/dev/null <<'TERMINFO_EOF'
		\(terminfoDump)
		TERMINFO_EOF
		    [ $? -ne 0 ] && export TERM=xterm-256color
		  else
		    export TERM=xterm-256color
		  fi
		fi
		exec "${SHELL:-/bin/sh}" -l
		"""
		return RemoteShellBootstrap(
			command: command,
			environment: [("TERM", "xterm-ghostty")]
		)
	}

	private static func invocationArgs(for options: [SSHOption]) throws -> [Arg] {
		var args: [Arg] = []
		for option in options {
			let rendered = try option.invocationArguments()
			guard rendered.count == 2,
			      let flag = rendered.first,
			      let value = rendered.last else { continue }
			args.append(.raw(flag))
			if case let .option(keyword) = option.kind,
			   keyword == "ExitOnForwardFailure" {
				args.append(.raw(value))
			} else {
				args.append(.quoted(value))
			}
		}
		return args
	}

	private static func renderCommand(_ args: [Arg]) -> String {
		args.map { arg -> String in
			switch arg {
			case let .raw(value): return value
			case let .quoted(value): return ShellQuote.posix(value)
			case let .verbatim(value): return value
			}
		}.joined(separator: " ")
	}

	/// Production entry point. Production callers route through this; the
	/// internal `_build` exposes test seams (`sshPath:`, `terminfoDump:`).
	public static func build(
		host: Host,
		askpassPath: String,
		knownHostsCaterm: String,
		knownHostsUser: String,
		installTerminfo: Bool = false,
		authenticationMode: SSHAuthenticationMode = .configuredCredential,
		automationEnvironment: [HostEnvironmentVariable]? = nil,
		credentialLookup: CredentialLookup? = nil
	) -> Output {
		do {
			return try buildValidated(
				host: host,
				askpassPath: askpassPath,
				knownHostsCaterm: knownHostsCaterm,
				knownHostsUser: knownHostsUser,
				installTerminfo: installTerminfo,
				authenticationMode: authenticationMode,
				automationEnvironment: automationEnvironment,
				credentialLookup: credentialLookup
			)
		} catch {
			NSLog("[SSHCommandBuilder] failed to build SSH command: \(error)")
			return Output(command: "/usr/bin/false", env: [])
		}
	}

	/// Throwing production entry point for connection flows that can surface
	/// invalid options or Host automation instead of replacing them with a
	/// sentinel command.
	public static func buildValidated(
		host: Host,
		askpassPath: String,
		knownHostsCaterm: String,
		knownHostsUser: String,
		installTerminfo: Bool = false,
		authenticationMode: SSHAuthenticationMode = .configuredCredential,
		automationEnvironment: [HostEnvironmentVariable]? = nil,
		credentialLookup: CredentialLookup? = nil
	) throws -> Output {
		try _buildValidated(
			host: host,
			askpassPath: askpassPath,
			knownHostsCaterm: knownHostsCaterm,
			knownHostsUser: knownHostsUser,
			installTerminfo: installTerminfo,
			sshPath: "/usr/bin/ssh",
			terminfoDump: TerminfoSource.terminfoDump(),
			authenticationMode: authenticationMode,
			automationEnvironment: automationEnvironment,
			credentialLookup: credentialLookup
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
		terminfoDump: String?,
		authenticationMode: SSHAuthenticationMode = .configuredCredential,
		automationEnvironment: [HostEnvironmentVariable]? = nil,
		credentialLookup: CredentialLookup? = nil
	) -> Output {
		do {
			return try _buildValidated(
				host: host,
				askpassPath: askpassPath,
				knownHostsCaterm: knownHostsCaterm,
				knownHostsUser: knownHostsUser,
				installTerminfo: installTerminfo,
				sshPath: sshPath,
				terminfoDump: terminfoDump,
				authenticationMode: authenticationMode,
				automationEnvironment: automationEnvironment,
				credentialLookup: credentialLookup
			)
		} catch {
			NSLog("[SSHCommandBuilder] failed to build test SSH command: \(error)")
			return Output(command: "/usr/bin/false", env: [])
		}
	}

	private static func _buildValidated(
		host: Host,
		askpassPath: String,
		knownHostsCaterm: String,
		knownHostsUser: String,
		installTerminfo: Bool,
		sshPath: String,
		terminfoDump: String?,
		authenticationMode: SSHAuthenticationMode,
		automationEnvironment: [HostEnvironmentVariable]?,
		credentialLookup: CredentialLookup?
	) throws -> Output {
		let sshArg: Arg = sshPath == "/usr/bin/ssh" ? .raw(sshPath) : .quoted(sshPath)
		var args: [Arg] = [sshArg]

		let plan = SSHConnectionPolicy.interactiveHostPlan(
			for: host,
			role: .target,
			knownHostsFiles: [knownHostsCaterm, knownHostsUser],
			authenticationMode: authenticationMode
		)
		args += try invocationArgs(for: plan.options)

		var env: [(String, String)] = []
		if let kind = plan.credentialKind {
			if let credentialLookup,
			   let account = credentialLookup.account(for: kind) {
				env = SSHCredentialContract.askpassEnvironment(
					executable: askpassPath,
					kind: kind,
					service: credentialLookup.service,
					account: account,
					useDataProtectionKeychain:
						credentialLookup.useDataProtectionKeychain
				)
			} else {
				env = SSHCredentialContract.askpassEnvironment(
					executable: askpassPath,
					hostID: host.id,
					kind: kind
				)
			}
		}

		let resolvedAutomationEnvironment = try environment(
			for: host,
			override: automationEnvironment
		)
		for variable in resolvedAutomationEnvironment {
			args += [
				.raw("-o"),
				.quoted("SetEnv=\(variable.name)=\(variable.value)"),
			]
		}

		args += [.raw("-p"), .raw(String(host.port))]

		let bootstrap = remoteShellBootstrap(
			installTerminfo: installTerminfo,
			terminfoDump: terminfoDump
		)
		if bootstrap != nil {
			args += [.raw("-t")]
		}

		// user@host with each side quoted, '@' literal between.
		let userHost = "\(ShellQuote.posix(host.username))@\(ShellQuote.posix(host.hostname))"
		args.append(.verbatim(userHost))

		if let bootstrap {
			args.append(.quoted(bootstrap.command))
			env += bootstrap.environment
		}

		return Output(command: renderCommand(args), env: env)
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
		terminfoDump: String? = nil,
		automationEnvironment: [HostEnvironmentVariable]? = nil,
		credentialLookups: [UUID: CredentialLookup] = [:]
	) throws -> Output {
		// Resolve the terminfo dump from the bundle when not supplied by the
		// caller. This mirrors the direct-path build overload which always
		// calls TerminfoSource.terminfoDump() internally.
		let resolvedDump: String? = terminfoDump ?? TerminfoSource.terminfoDump()
		if ancestors.isEmpty {
			return try _buildValidated(
				host: host,
				askpassPath: askpassPath,
				knownHostsCaterm: knownHostsCaterm,
				knownHostsUser: knownHostsUser,
				installTerminfo: installTerminfo,
				sshPath: sshPath,
				terminfoDump: resolvedDump,
				authenticationMode: .configuredCredential,
				automationEnvironment: automationEnvironment,
				credentialLookup: credentialLookups[host.id]
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
			terminfoDump: resolvedDump,
			automationEnvironment: automationEnvironment,
			credentialLookups: credentialLookups
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
		terminfoDump: String?,
		automationEnvironment: [HostEnvironmentVariable]?,
		credentialLookups: [UUID: CredentialLookup]
	) throws -> Output {
		// Full hop list in dial order: [deepest ancestor … target]
		let hops: [SSHHost] = ancestors + [target]

		// Build one Host block per hop. May throw SSHConfigQuoteError if
		// any hostname / value contains a control character.
		var blocks: [String] = []
		var plans: [SSHHostPlan] = []
		for (index, hop) in hops.enumerated() {
			let alias = "caterm-h-\(hop.id.uuidString)"
			let plan = SSHConnectionPolicy.interactiveHostPlan(
				for: hop,
				role: index == hops.count - 1 ? .target : .jump,
				knownHostsFiles: [knownHostsCaterm, knownHostsUser]
			)
			plans.append(plan)

			var lines: [String] = ["Host \(alias)"]
			lines.append("\tHostName \(try SSHConfigQuote.encode(hop.hostname))")
			lines.append("\tPort \(hop.port)")
			lines.append("\tUser \(try SSHConfigQuote.encode(hop.username))")

			// ProxyJump: every hop except the deepest (index 0) points at
			// the previous hop's alias.
			if index > 0 {
				let prevAlias = "caterm-h-\(hops[index - 1].id.uuidString)"
				lines.append("\tProxyJump \(prevAlias)")
			}

			for option in plan.options {
				lines.append("\t\(try option.configLine())")
			}
			if index == hops.count - 1 {
				for variable in try environment(
					for: hop,
					override: automationEnvironment
				) {
					let assignment = "\(variable.name)=\(variable.value)"
					lines.append("\tSetEnv \(try SSHConfigQuote.encode(assignment))")
				}
			}

			blocks.append(lines.joined(separator: "\n"))
		}

		let configContent = blocks.joined(separator: "\n\n") + "\n"
		let configURL = try configSink.write(configContent)

		// Askpass is process-wide for a chain. The chain payload identifies the
		// concrete hop and credential kind when the helper receives a prompt.
		var env: [(String, String)] = plans.contains(where: \.needsAskpass)
			? SSHCredentialContract.askpassEnvironment(executable: askpassPath)
			: []

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
			if let lookup = credentialLookups[hop.id] {
				entry["credentialService"] = lookup.service
				entry["passwordAccount"] = lookup.passwordAccount
				entry["passphraseAccount"] = lookup.passphraseAccount
				entry["useDataProtectionKeychain"] =
					lookup.useDataProtectionKeychain
			}
			if case let .keyFile(keyPath, _) = hop.credential {
				entry["keyPath"] = keyPath
			}
			chainEntries.append(entry)
		}
		let chainData = try JSONSerialization.data(withJSONObject: chainEntries, options: [.sortedKeys])
		let chainJSON = String(data: chainData, encoding: .utf8) ?? "[]"
		env.append((SSHCredentialEnvironmentKey.chain.rawValue, chainJSON))
		env.append((
			SSHCredentialEnvironmentKey.chainStatePath.rawValue,
			configURL.path + ".askpass-state"
		))

		// Assemble the final command: ssh -F <configPath> caterm-h-<target-uuid>
		let targetAlias = "caterm-h-\(target.id.uuidString)"
		let sshArg: String = sshPath == "/usr/bin/ssh" ? sshPath : ShellQuote.posix(sshPath)
		let configPathArg = ShellQuote.posix(configURL.path)

		let bootstrap = remoteShellBootstrap(
			installTerminfo: installTerminfo,
			terminfoDump: terminfoDump
		)
		var cmdParts: [String] = [sshArg, "-F", configPathArg]
		if bootstrap != nil {
			cmdParts.append("-t")
		}
		cmdParts.append(targetAlias)

		if let bootstrap {
			cmdParts.append(ShellQuote.posix(bootstrap.command))
			env += bootstrap.environment
		}

		let cmd = cmdParts.joined(separator: " ")
		return Output(command: cmd, env: env, configURL: configURL)
	}

	private static func environment(
		for host: SSHHost,
		override: [HostEnvironmentVariable]?
	) throws -> [HostEnvironmentVariable] {
		if let override {
			return try HostAutomation(
				environment: override
			).validated().environment
		}
		guard host.automation.isEnabled else { return [] }
		return try host.automation.validated().environment
	}
}
