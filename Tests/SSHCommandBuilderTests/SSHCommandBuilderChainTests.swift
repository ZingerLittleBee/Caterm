import XCTest
@testable import SSHCommandBuilder

final class SSHCommandBuilderChainTests: XCTestCase {
	private func host(_ name: String, _ serverId: String?,
	                  jump: String? = nil,
	                  cred: CredentialSource = .password) -> SSHHost {
		var h = SSHHost(name: name, hostname: "\(name).example.com",
		                port: 22, username: "u", credential: cred)
		h.serverId = serverId
		h.jumpHostServerId = jump
		return h
	}

	func testDirectHostProducesNoConfigURL() throws {
		let target = host("target", "rh-target")
		let sink = InMemorySSHConfigSink()
		let out = try SSHCommandBuilder.build(
			host: target, ancestors: [],
			configSink: sink,
			askpassPath: "/usr/local/bin/caterm-askpass",
			knownHostsCaterm: "/k1", knownHostsUser: "/k2",
			installTerminfo: false, sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)
		XCTAssertNil(out.configURL)
		XCTAssertTrue(sink.writes.isEmpty)
	}

	func testSingleHopWritesConfigAndCommandUsesAlias() throws {
		let bastion = host("bastion", "rh-bastion")
		let target = host("target", "rh-target", jump: "rh-bastion")
		let sink = InMemorySSHConfigSink()
		let out = try SSHCommandBuilder.build(
			host: target, ancestors: [bastion],
			configSink: sink,
			askpassPath: "/usr/local/bin/caterm-askpass",
			knownHostsCaterm: "/k1", knownHostsUser: "/k2",
			installTerminfo: false, sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)
		XCTAssertNotNil(out.configURL)
		XCTAssertEqual(sink.writes.count, 1)
		let config = sink.writes[0].1

		// Both Host blocks present, aliased "caterm-h-<uuid>".
		XCTAssertTrue(config.contains("Host caterm-h-\(bastion.id.uuidString)"))
		XCTAssertTrue(config.contains("Host caterm-h-\(target.id.uuidString)"))
		// Target block carries ProxyJump pointing at bastion's alias.
		XCTAssertTrue(config.contains(
			"ProxyJump caterm-h-\(bastion.id.uuidString)"),
			"target Host block must reference the ancestor alias")
		// Command uses the target alias.
		XCTAssertTrue(out.command.contains(
			"caterm-h-\(target.id.uuidString)"))
		// Full command shape: -F '<configPath>' caterm-h-<target-uuid>
		// configURL.path returns "/0" (non-empty due to triple-slash tmpfs:///0),
		// which ShellQuote.posix wraps in single quotes in the emitted command.
		let expectedFlag = "-F \(ShellQuote.posix(out.configURL!.path)) caterm-h-\(target.id.uuidString)"
		XCTAssertTrue(out.command.contains(expectedFlag),
		              "expected command to contain '\(expectedFlag)', got: \(out.command)")
	}

	func testChainUsesExplicitControlPathForEveryHop() throws {
		let bastion = host("bastion", "rh-bastion")
		let target = host("target", "rh-target", jump: "rh-bastion")
		let bastionPath = "/tmp/caterm isolated/\(bastion.id.uuidString).sock"
		let targetPath = "/tmp/caterm isolated/\(target.id.uuidString).sock"
		let sink = InMemorySSHConfigSink()

		_ = try SSHCommandBuilder.build(
			host: target,
			ancestors: [bastion],
			configSink: sink,
			askpassPath: "/usr/local/bin/caterm-askpass",
			knownHostsCaterm: "/k1",
			knownHostsUser: "/k2",
			controlPaths: [
				bastion.id: bastionPath,
				target.id: targetPath,
			]
		)
		let config = try XCTUnwrap(sink.writes.first?.1)

		XCTAssertTrue(config.contains("ControlPath \"\(bastionPath)\""))
		XCTAssertTrue(config.contains("ControlPath \"\(targetPath)\""))
		XCTAssertFalse(config.contains("~/Library/Caches/Caterm/cm/"))
	}

	func testChainScopesCertificateAndAgentToTheirHosts() throws {
		let bastion = host(
			"bastion",
			"rh-bastion",
			cred: .agent
		)
		let target = host(
			"target",
			"rh-target",
			jump: "rh-bastion",
			cred: .keyFile(
				keyPath: "/managed/key",
				hasPassphrase: false
			)
		)
		let sink = InMemorySSHConfigSink()

		_ = try SSHCommandBuilder.build(
			host: target,
			ancestors: [bastion],
			configSink: sink,
			askpassPath: "/askpass",
			knownHostsCaterm: "/A",
			knownHostsUser: "/B",
			runtimeIdentities: [
				bastion.id: .init(
					identityAgentPath: "/session/bastion.sock"
				),
				target.id: .init(
					certificatePath: "/session/target-cert.pub"
				),
			]
		)
		let config = try XCTUnwrap(sink.writes.first?.1)
		let bastionBlock = blockFor(
			"caterm-h-\(bastion.id.uuidString)",
			in: config
		)
		let targetBlock = blockFor(
			"caterm-h-\(target.id.uuidString)",
			in: config
		)

		XCTAssertTrue(
			bastionBlock.contains(
				"IdentityAgent /session/bastion.sock"
			)
		)
		XCTAssertFalse(bastionBlock.contains("CertificateFile"))
		XCTAssertTrue(
			targetBlock.contains(
				"CertificateFile /session/target-cert.pub"
			)
		)
		XCTAssertFalse(targetBlock.contains("IdentityAgent"))
	}

	func testKnownHostsFilesAreSeparateTokensInGeneratedConfig() throws {
		let bastion = host("bastion", "rh-bastion")
		let target = host("target", "rh-target", jump: "rh-bastion")
		let sink = InMemorySSHConfigSink()
		_ = try SSHCommandBuilder.build(
			host: target, ancestors: [bastion],
			configSink: sink,
			askpassPath: "/usr/local/bin/caterm-askpass",
			knownHostsCaterm: "/Users/a/Library/Application Support/Caterm/known_hosts",
			knownHostsUser: "/Users/a/.ssh/known_hosts",
			installTerminfo: false, sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)
		let config = sink.writes[0].1

		XCTAssertTrue(config.contains(
			"UserKnownHostsFile \"/Users/a/Library/Application Support/Caterm/known_hosts\" /Users/a/.ssh/known_hosts"
		), "known-host files must be emitted as two ssh_config arguments, got:\n\(config)")
		XCTAssertFalse(config.contains(
			"UserKnownHostsFile \"/Users/a/Library/Application Support/Caterm/known_hosts /Users/a/.ssh/known_hosts\""
		), "quoting both paths as one value makes OpenSSH use an invalid filename")
	}

	func testMultiHopConfigHasProxyJumpExceptOnDeepest() throws {
		let deep = host("deep", "rh-deep")
		let mid = host("mid", "rh-mid", jump: "rh-deep")
		let target = host("target", "rh-target", jump: "rh-mid")
		let sink = InMemorySSHConfigSink()
		_ = try SSHCommandBuilder.build(
			host: target, ancestors: [deep, mid],
			configSink: sink,
			askpassPath: "/usr/local/bin/caterm-askpass",
			knownHostsCaterm: "/k1", knownHostsUser: "/k2",
			installTerminfo: false, sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)
		let config = sink.writes[0].1

		let deepBlock = blockFor("caterm-h-\(deep.id.uuidString)", in: config)
		XCTAssertFalse(deepBlock.contains("ProxyJump"))
		let midBlock = blockFor("caterm-h-\(mid.id.uuidString)", in: config)
		XCTAssertTrue(midBlock.contains(
			"ProxyJump caterm-h-\(deep.id.uuidString)"))
		let targetBlock = blockFor("caterm-h-\(target.id.uuidString)", in: config)
		XCTAssertTrue(targetBlock.contains(
			"ProxyJump caterm-h-\(mid.id.uuidString)"))
	}

	func testCATERMChainEnvContainsEveryHopWithMatchingAliases() throws {
		let bastion = host("bastion", "rh-bastion",
			cred: .keyFile(keyPath: "/k", hasPassphrase: true))
		let target = host("target", "rh-target", jump: "rh-bastion")
		let sink = InMemorySSHConfigSink()
		let out = try SSHCommandBuilder.build(
			host: target, ancestors: [bastion],
			configSink: sink,
			askpassPath: "/usr/local/bin/caterm-askpass",
			knownHostsCaterm: "/k1", knownHostsUser: "/k2",
			installTerminfo: false, sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)
		guard let chainJSON = out.env.first(where: { $0.0 == "CATERM_CHAIN" })?.1
		else { return XCTFail("CATERM_CHAIN not set on chain") }
		let data = Data(chainJSON.utf8)
		guard let array = try JSONSerialization.jsonObject(with: data)
				as? [[String: Any]]
		else { return XCTFail("CATERM_CHAIN is not a JSON array") }
		XCTAssertEqual(array.count, 2)
		let aliases = array.compactMap { $0["alias"] as? String }
		XCTAssertEqual(Set(aliases), Set([
			"caterm-h-\(bastion.id.uuidString)",
			"caterm-h-\(target.id.uuidString)",
		]))
		let config = sink.writes[0].1
		for alias in aliases {
			XCTAssertTrue(config.contains("Host \(alias)"),
			              "alias \(alias) missing from ssh_config")
		}
	}

	func testChainCarriesPerHopIdentityCredentialLocations() throws {
		let bastion = host("bastion", "rh-bastion")
		let target = host(
			"target",
			"rh-target",
			jump: "rh-bastion",
			cred: .keyFile(keyPath: "/managed/key", hasPassphrase: true)
		)
		let lookup = SSHCommandBuilder.CredentialLookup(
			service: "com.caterm.identities",
			passphraseAccount: "identity.material.passphrase",
			useDataProtectionKeychain: true
		)
		let output = try SSHCommandBuilder.build(
			host: target,
			ancestors: [bastion],
			configSink: InMemorySSHConfigSink(),
			askpassPath: "/askpass",
			knownHostsCaterm: "/k1",
			knownHostsUser: "/k2",
			terminfoDump: "",
			credentialLookups: [target.id: lookup]
		)
		let json = try XCTUnwrap(
			output.env.first { $0.0 == "CATERM_CHAIN" }?.1
		)
		let entries = try XCTUnwrap(
			JSONSerialization.jsonObject(with: Data(json.utf8))
				as? [[String: Any]]
		)
		let targetEntry = try XCTUnwrap(entries.first {
			$0["alias"] as? String
				== "caterm-h-\(target.id.uuidString)"
		})

		XCTAssertEqual(
			targetEntry["credentialService"] as? String,
			"com.caterm.identities"
		)
		XCTAssertEqual(
			targetEntry["passphraseAccount"] as? String,
			"identity.material.passphrase"
		)
		XCTAssertEqual(
			targetEntry["useDataProtectionKeychain"] as? Bool,
			true
		)
	}

	func testCATERMChainStatePathTracksConfigFilePath() throws {
		let bastion = host("bastion", "rh-bastion")
		let target = host("target", "rh-target", jump: "rh-bastion")
		let sink = InMemorySSHConfigSink()
		let out = try SSHCommandBuilder.build(
			host: target, ancestors: [bastion],
			configSink: sink,
			askpassPath: "/usr/local/bin/caterm-askpass",
			knownHostsCaterm: "/k1", knownHostsUser: "/k2",
			installTerminfo: false, sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)

		let env = Dictionary(uniqueKeysWithValues: out.env)
		XCTAssertEqual(
			env["CATERM_CHAIN_STATE_PATH"],
			out.configURL?.path.appending(".askpass-state")
		)
	}

	func testNewlineInHostnameThrowsControlCharacter() {
		var bastion = host("bastion", "rh-bastion")
		bastion.hostname = "bastion.example.com\nProxyCommand /tmp/evil"
		let target = host("target", "rh-target", jump: "rh-bastion")
		let sink = InMemorySSHConfigSink()
		XCTAssertThrowsError(try SSHCommandBuilder.build(
			host: target, ancestors: [bastion],
			configSink: sink,
			askpassPath: "/usr/local/bin/caterm-askpass",
			knownHostsCaterm: "/k1", knownHostsUser: "/k2",
			installTerminfo: false, sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)) { error in
			XCTAssertEqual(error as? SSHConfigQuoteError, .controlCharacter)
		}
		XCTAssertTrue(sink.writes.isEmpty)
	}

	func testCATERMChainEnvHasSortedJSONKeys() throws {
		let bastion = host("bastion", "rh-bastion",
			cred: .keyFile(keyPath: "/k", hasPassphrase: false))
		let target = host("target", "rh-target", jump: "rh-bastion")
		let sink = InMemorySSHConfigSink()
		let out = try SSHCommandBuilder.build(
			host: target, ancestors: [bastion],
			configSink: sink,
			askpassPath: "/usr/local/bin/caterm-askpass",
			knownHostsCaterm: "/k1", knownHostsUser: "/k2",
			installTerminfo: false, sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)
		guard let json = out.env.first(where: { $0.0 == "CATERM_CHAIN" })?.1
		else { return XCTFail("no CATERM_CHAIN") }
		// With .sortedKeys, the first hop's first key is "alias",
		// because alphabetically "alias" < "hostId" < "hostname" < "keyPath" < "port" < "user".
		XCTAssertTrue(json.contains("\"alias\""), "json must contain alias key")
		// Heuristic: the literal `"alias":` must appear before `"hostId":` for
		// every entry, demonstrating .sortedKeys is in effect.
		let aliasIdx = json.range(of: "\"alias\"")!.lowerBound
		let hostIdIdx = json.range(of: "\"hostId\"")!.lowerBound
		XCTAssertLessThan(aliasIdx, hostIdIdx,
			"with .sortedKeys, 'alias' must come before 'hostId' alphabetically; json=\(json)")
	}

	func testPasswordJumpActivatesAskpassForAgentTarget() throws {
		let jump = host("jump", "rh-jump", cred: .password)
		let target = host("target", "rh-target", jump: "rh-jump", cred: .agent)
		let out = try SSHCommandBuilder.build(
			host: target,
			ancestors: [jump],
			configSink: InMemorySSHConfigSink(),
			askpassPath: "/tmp/caterm-askpass",
			knownHostsCaterm: "/k1",
			knownHostsUser: "/k2",
			terminfoDump: ""
		)
		let environment = Dictionary(uniqueKeysWithValues: out.env)

		XCTAssertEqual(environment["SSH_ASKPASS"], "/tmp/caterm-askpass")
		XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
		XCTAssertNil(environment["CATERM_HOST_ID"])
		XCTAssertNil(environment["CATERM_ASKPASS_KIND"])
	}

	func testPassphrasedKeyJumpActivatesAskpassForPasswordlessKeyTarget() throws {
		let jump = host(
			"jump",
			"rh-jump",
			cred: .keyFile(keyPath: "/jump-key", hasPassphrase: true)
		)
		let target = host(
			"target",
			"rh-target",
			jump: "rh-jump",
			cred: .keyFile(keyPath: "/target-key", hasPassphrase: false)
		)
		let out = try SSHCommandBuilder.build(
			host: target,
			ancestors: [jump],
			configSink: InMemorySSHConfigSink(),
			askpassPath: "/tmp/caterm-askpass",
			knownHostsCaterm: "/k1",
			knownHostsUser: "/k2",
			terminfoDump: ""
		)
		let environment = Dictionary(uniqueKeysWithValues: out.env)

		XCTAssertEqual(environment["SSH_ASKPASS"], "/tmp/caterm-askpass")
		XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
	}

	func testAllAgentChainDoesNotActivateAskpass() throws {
		let jump = host("jump", "rh-jump", cred: .agent)
		let target = host("target", "rh-target", jump: "rh-jump", cred: .agent)
		let out = try SSHCommandBuilder.build(
			host: target,
			ancestors: [jump],
			configSink: InMemorySSHConfigSink(),
			askpassPath: "/tmp/caterm-askpass",
			knownHostsCaterm: "/k1",
			knownHostsUser: "/k2",
			terminfoDump: ""
		)
		let environment = Dictionary(uniqueKeysWithValues: out.env)

		XCTAssertNil(environment["SSH_ASKPASS"])
		XCTAssertNil(environment["SSH_ASKPASS_REQUIRE"])
		XCTAssertNotNil(environment["CATERM_CHAIN"])
	}

	func testDirectAndChainShareTerminfoBootstrap() throws {
		let dump = "xterm-ghostty|test terminal,\n\tam, cols#80,"
		let target = host("target", "rh-target", jump: "rh-jump", cred: .agent)
		let direct = SSHCommandBuilder._build(
			host: target,
			askpassPath: "/tmp/caterm-askpass",
			knownHostsCaterm: "/k1",
			knownHostsUser: "/k2",
			installTerminfo: true,
			sshPath: "/usr/bin/ssh",
			terminfoDump: dump
		)
		let chain = try SSHCommandBuilder.build(
			host: target,
			ancestors: [host("jump", "rh-jump", cred: .agent)],
			configSink: InMemorySSHConfigSink(),
			askpassPath: "/tmp/caterm-askpass",
			knownHostsCaterm: "/k1",
			knownHostsUser: "/k2",
			installTerminfo: true,
			terminfoDump: dump
		)
		let marker = "if ! infocmp xterm-ghostty"
		guard let directStart = direct.command.range(of: marker)?.lowerBound,
		      let chainStart = chain.command.range(of: marker)?.lowerBound else {
			return XCTFail("missing terminfo bootstrap")
		}

		XCTAssertEqual(String(direct.command[directStart...]), String(chain.command[chainStart...]))
		XCTAssertEqual(direct.env.first(where: { $0.0 == "TERM" })?.1, "xterm-ghostty")
		XCTAssertEqual(chain.env.first(where: { $0.0 == "TERM" })?.1, "xterm-ghostty")
	}

	private func blockFor(_ alias: String, in config: String) -> String {
		let lines = config.split(separator: "\n").map(String.init)
		guard let start = lines.firstIndex(where: { $0.hasPrefix("Host \(alias)") })
		else { return "" }
		var end = lines.count
		for i in (start + 1)..<lines.count {
			if lines[i].hasPrefix("Host ") { end = i; break }
		}
		return lines[start..<end].joined(separator: "\n")
	}
}
