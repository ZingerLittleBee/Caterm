import XCTest
@testable import SSHCommandBuilder

/// The LocalCommand beacon prints an OSC 0 title sequence the moment the
/// connection is established, so `onSessionLive` (and the connecting-overlay
/// dismissal) no longer depends on the remote shell emitting a title.
final class LocalCommandBeaconTests: XCTestCase {
	private func host(_ name: String, jump: String? = nil,
	                  cred: CredentialSource = .password) -> SSHHost {
		var h = SSHHost(name: name, hostname: "\(name).example.com",
		                port: 22, username: "u", credential: cred)
		h.serverId = "rh-\(name)"
		h.jumpHostServerId = jump
		return h
	}

	func testDirectPathEmitsBeaconOptions() {
		let out = SSHCommandBuilder._build(
			host: host("target"),
			askpassPath: "/tmp/askpass",
			knownHostsCaterm: "/k1",
			knownHostsUser: "/k2",
			installTerminfo: false,
			sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)
		XCTAssertTrue(out.command.contains("-o 'PermitLocalCommand=yes'"))
		// ShellQuote.posix turns the embedded single quotes into '\'' — the
		// argv ssh receives must be exactly:
		//   LocalCommand=printf '\033]0;\007'
		XCTAssertTrue(
			out.command.contains("-o 'LocalCommand=printf '\\''\\033]0;\\007'\\'''"),
			"beacon must survive shell quoting byte-for-byte, got: \(out.command)"
		)
	}

	func testBeaconPrecedesUserHostInDirectCommand() throws {
		let out = SSHCommandBuilder._build(
			host: host("target"),
			askpassPath: "/tmp/askpass",
			knownHostsCaterm: "/k1",
			knownHostsUser: "/k2",
			installTerminfo: false,
			sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)
		let beaconRange = try XCTUnwrap(out.command.range(of: "PermitLocalCommand"))
		let hostRange = try XCTUnwrap(out.command.range(of: "@'target.example.com'"))
		XCTAssertTrue(beaconRange.lowerBound < hostRange.lowerBound,
		              "options must come before the user@host operand")
	}

	func testChainConfigEmitsBeaconOnTargetOnly() throws {
		let bastion = host("bastion")
		let target = host("target", jump: "rh-bastion")
		let sink = InMemorySSHConfigSink()
		_ = try SSHCommandBuilder.build(
			host: target, ancestors: [bastion],
			configSink: sink,
			askpassPath: "/tmp/askpass",
			knownHostsCaterm: "/k1", knownHostsUser: "/k2",
			installTerminfo: false, sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)
		let config = sink.writes[0].1
		let bastionBlock = try hostBlock(alias: "caterm-h-\(bastion.id.uuidString)", in: config)
		let targetBlock = try hostBlock(alias: "caterm-h-\(target.id.uuidString)", in: config)

		XCTAssertTrue(targetBlock.contains("PermitLocalCommand yes"))
		XCTAssertTrue(targetBlock.contains("LocalCommand printf '\\033]0;\\007'"))
		// A beacon on a jump hop would printf into the `ssh -W` tunnel and
		// corrupt the next hop's SSH byte stream — it must never appear there.
		XCTAssertFalse(bastionBlock.contains("LocalCommand"),
		               "jump hop must not carry the beacon:\n\(bastionBlock)")
		XCTAssertFalse(bastionBlock.contains("PermitLocalCommand"))
	}

	/// Extract one `Host <alias>` block (up to the next `Host ` line).
	private func hostBlock(alias: String, in config: String) throws -> String {
		let lines = config.components(separatedBy: "\n")
		let start = try XCTUnwrap(
			lines.firstIndex(where: { $0.hasPrefix("Host \(alias)") }),
			"missing Host block for \(alias) in:\n\(config)"
		)
		var end = lines.count
		for i in (start + 1)..<lines.count where lines[i].hasPrefix("Host ") {
			end = i
			break
		}
		return lines[start..<end].joined(separator: "\n")
	}
}
