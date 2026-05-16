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
