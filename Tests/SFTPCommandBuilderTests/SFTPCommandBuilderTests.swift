import XCTest
@testable import SFTPCommandBuilder
import SSHCommandBuilder

final class SFTPCommandBuilderTests: XCTestCase {
	func makeCreds(extras: [String: String] = [:]) -> SFTPCredentials {
		SFTPCredentials(
			knownHostsCaterm: URL(fileURLWithPath: "/tmp/caterm_kh"),
			knownHostsUser: URL(fileURLWithPath: "/tmp/user_kh"),
			strictHostKeyChecking: .acceptNew,
			extraSSHOptions: extras
		)
	}
	func makeHost() -> SSHHost {
		SSHHost(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
		        name: "demo", hostname: "h.example", port: 22,
		        username: "alice", credential: .agent)
	}

	func testListInvocationContainsNoFallbackOptions() throws {
		let inv = try SFTPCommandBuilder.invocation(
			host: makeHost(),
			controlPath: URL(fileURLWithPath: "/tmp/cm/x.sock"),
			credentials: makeCreds(),
			operation: .list(remoteDir: "/etc")
		)
		let argvJoined = inv.argv.joined(separator: " ")
		XCTAssertTrue(argvJoined.contains("-o ControlMaster=no"))
		XCTAssertTrue(argvJoined.contains("-o BatchMode=yes"))
		XCTAssertTrue(argvJoined.contains("-o PreferredAuthentications=none"))
		XCTAssertTrue(argvJoined.contains("-o ProxyCommand=none"))
		XCTAssertTrue(argvJoined.contains("-o ControlPath=/tmp/cm/x.sock"))
		XCTAssertTrue(inv.argv.first == "/usr/bin/sftp")
	}

	func testKnownHostsJoined() throws {
		let inv = try SFTPCommandBuilder.invocation(
			host: makeHost(),
			controlPath: URL(fileURLWithPath: "/tmp/cm/x.sock"),
			credentials: makeCreds(),
			operation: .list(remoteDir: "/")
		)
		XCTAssertTrue(inv.argv.joined(separator: " ")
			.contains("-o UserKnownHostsFile=/tmp/caterm_kh /tmp/user_kh"))
	}

	func testKnownHostsWithSpacesRemainSeparateConfigTokens() throws {
		let credentials = SFTPCredentials(
			knownHostsCaterm: URL(fileURLWithPath:
				"/Users/alice/Library/Application Support/Caterm/known_hosts"),
			knownHostsUser: URL(fileURLWithPath:
				"/Users/alice/SSH\\ Files/known_hosts"),
			strictHostKeyChecking: .acceptNew
		)
		let invocation = try SFTPCommandBuilder.invocation(
			host: makeHost(),
			controlPath: URL(fileURLWithPath: "/tmp/cm/x.sock"),
			credentials: credentials,
			operation: .list(remoteDir: "/")
		)

		XCTAssertTrue(invocation.argv.contains(
			"UserKnownHostsFile=\"/Users/alice/Library/Application Support/Caterm/known_hosts\" " +
				"\"/Users/alice/SSH\\\\ Files/known_hosts\""
		))
	}

	func testReuseOnlyInvocationCarriesNoFreshAuthenticationMaterial() throws {
		let invocation = try SFTPCommandBuilder.invocation(
			host: makeHost(),
			controlPath: URL(fileURLWithPath: "/tmp/cm/x.sock"),
			credentials: makeCreds(),
			operation: .list(remoteDir: "/")
		)

		XCTAssertTrue(invocation.environment.isEmpty)
		XCTAssertFalse(invocation.argv.contains("-i"))
	}

	func testNoFallbackOptionsFirst() throws {
		let inv = try SFTPCommandBuilder.invocation(
			host: makeHost(),
			controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
			credentials: makeCreds(extras: ["LogLevel": "DEBUG3"]),
			operation: .list(remoteDir: "/")
		)
		let preferredIdx = inv.argv.firstIndex(of: "PreferredAuthentications=none")!
		let userIdx = inv.argv.firstIndex(of: "LogLevel=DEBUG3")!
		XCTAssertLessThan(preferredIdx, userIdx)
	}

	func testExtraOptionsCannotOverrideNoFallback() throws {
		let inv = try SFTPCommandBuilder.invocation(
			host: makeHost(),
			controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
			credentials: makeCreds(extras: [
				"PreferredAuthentications": "publickey",
				"BatchMode": "no",
				"ControlMaster": "auto",
				"ProxyJump": "bastion",
			]),
			operation: .list(remoteDir: "/")
		)
		let joined = inv.argv.joined(separator: " ")
		XCTAssertFalse(joined.contains("publickey"))
		XCTAssertFalse(joined.contains("BatchMode=no"))
		XCTAssertFalse(joined.contains("ControlMaster=auto"))
		XCTAssertFalse(joined.contains("ProxyJump"))
		XCTAssertFalse(joined.contains("bastion"))
	}

	func testDenylistIsCaseInsensitive() throws {
		let inv = try SFTPCommandBuilder.invocation(
			host: makeHost(),
			controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
			credentials: makeCreds(extras: [
				"preferredauthentications": "publickey",
				"BATCHMODE": "no",
				"Hostname": "evil.example",
				"PROXYCOMMAND": "nc evil 22",
			]),
			operation: .list(remoteDir: "/")
		)
		let joined = inv.argv.joined(separator: " ")
		XCTAssertFalse(joined.contains("evil.example"))
		XCTAssertFalse(joined.contains("nc evil"))
		XCTAssertFalse(joined.contains("publickey"))
		XCTAssertTrue(joined.contains("alice@h.example"))
	}

	func testListBatchScript() throws {
		let inv = try SFTPCommandBuilder.invocation(
			host: makeHost(),
			controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
			credentials: makeCreds(),
			operation: .list(remoteDir: "/etc")
		)
		XCTAssertEqual(inv.scriptStdin, "cd \"/etc\"\nls -la\nexit\n")
	}

	func testPutBatchScriptUsesLowercaseP() throws {
		let inv = try SFTPCommandBuilder.invocation(
			host: makeHost(),
			controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
			credentials: makeCreds(),
			operation: .put(localPath: URL(fileURLWithPath: "/local/a.txt"),
			                remotePath: "/srv/a.txt", recursive: false, resume: false)
		)
		XCTAssertEqual(inv.scriptStdin,
		               #"put -p "/local/a.txt" "/srv/a.txt"\#nexit\#n"#)
	}

	func testPutRecursive() throws {
		let inv = try SFTPCommandBuilder.invocation(
			host: makeHost(), controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
			credentials: makeCreds(),
			operation: .put(localPath: URL(fileURLWithPath: "/local/dir"),
			                remotePath: "/srv/dir", recursive: true, resume: false)
		)
		XCTAssertTrue(inv.scriptStdin.hasPrefix(#"put -pR "/local/dir" "/srv/dir""#))
	}

	func testRetryAddsResumeFlag() throws {
		let inv = try SFTPCommandBuilder.invocation(
			host: makeHost(), controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
			credentials: makeCreds(),
			operation: .put(localPath: URL(fileURLWithPath: "/a"),
			                remotePath: "/b", recursive: false, resume: true)
		)
		XCTAssertTrue(inv.scriptStdin.hasPrefix(#"put -pa "/a" "/b""#))
	}

	func testCombinedPathLengthRejected() {
		let big = "/" + String(repeating: "x", count: 600)
		XCTAssertThrowsError(try SFTPCommandBuilder.invocation(
			host: makeHost(), controlPath: URL(fileURLWithPath: "/tmp/x.sock"),
			credentials: makeCreds(),
			operation: .rename(from: big, to: big)
		)) { err in
			guard case SFTPBatchLineError.lineTooLong(let bytes, let limit) = err else {
				return XCTFail("got \(err)")
			}
			XCTAssertGreaterThan(bytes, 1023)
			XCTAssertEqual(limit, 1023)
		}
	}
}
