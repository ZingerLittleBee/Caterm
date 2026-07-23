import XCTest
@testable import SessionStore
@testable import SSHCommandBuilder

@MainActor
final class SessionStoreChainTests: XCTestCase {
	private func host(_ name: String, _ serverId: String?,
	                  jump: String? = nil,
	                  cred: CredentialSource = .password) -> SSHHost {
		var h = SSHHost(name: name, hostname: "\(name).example.com",
		                port: 22, username: "u", credential: cred)
		h.serverId = serverId
		h.jumpHostServerId = jump
		return h
	}

	private func localHost(_ name: String,
	                       jumpId: UUID? = nil,
	                       cred: CredentialSource = .password) -> SSHHost {
		var h = SSHHost(name: name, hostname: "\(name).example.com",
		                port: 22, username: "u", credential: cred)
		h.jumpHostId = jumpId
		return h
	}

	func testOpenTabFailsFastOnBrokenChain() throws {
		let target = host("target", "rh-target", jump: "rh-ghost")
		let store = SessionStore.makeForTest(hosts: [target])
		let tabId = store.openTab(host: target)
		guard case .failed(let kind) = store.tabs.first(where: { $0.id == tabId })?.state
		else { return XCTFail("tab not failed") }
		guard case .networkUnreachable(.other(_, let msg)) = kind
		else { return XCTFail("wrong failure kind: \(kind)") }
		XCTAssertTrue(msg.contains("Jump host chain is broken"),
		              "got: \(msg)")
	}

	func testOpenTabFailsFastOnMissingCredentialOnAncestor() async throws {
		let bastion = host("bastion", "rh-bastion")
		let target = host("target", "rh-target", jump: "rh-bastion")
		let store = SessionStore.makeForTest(hosts: [bastion, target])
		let tabId = store.openTab(host: target)
		await store.awaitConnectionAttempt(tabId: tabId)
		guard case .failed(let kind) = store.tabs.first(where: { $0.id == tabId })?.state,
		      case .networkUnreachable(.other(_, let msg)) = kind
		else { return XCTFail("expected failed networkUnreachable.other") }
		XCTAssertTrue(msg.contains("bastion") &&
		              msg.contains("needs credentials configured first"),
		              "got: \(msg)")
	}

	func testOpenTabUsesUnsyncedAncestorReferencedByLocalId() throws {
		let bastion = localHost("bastion", cred: .agent)
		var target = localHost("target")
		target.jumpHostId = bastion.id
		let store = SessionStore.makeForTest(hosts: [bastion, target])

		let tabId = store.openTab(host: target)
		let tab = store.tabs.first(where: { $0.id == tabId })!
		XCTAssertEqual(tab.resolvedChain.map(\.id), [bastion.id])
	}

	func testSetServerIdBackfillsDependentJumpHostServerIds() throws {
		let bastion = localHost("bastion")
		var target = localHost("target")
		target.jumpHostId = bastion.id
		let store = SessionStore.makeForTest(hosts: [bastion, target])

		try store.setServerId("rh-bastion", for: bastion.id)

		let refreshedTarget = try XCTUnwrap(store.hosts.first(where: { $0.id == target.id }))
		XCTAssertEqual(refreshedTarget.jumpHostServerId, "rh-bastion")
	}

	func testOpenTabPopulatesResolvedChainOnSuccess() throws {
		let bastion = host("bastion", "rh-bastion", cred: .agent)
		let target = host("target", "rh-target", jump: "rh-bastion")
		let store = SessionStore.makeForTest(hosts: [bastion, target])
		let tabId = store.openTab(host: target)
		let tab = store.tabs.first(where: { $0.id == tabId })!
		XCTAssertEqual(tab.resolvedChain.map(\.serverId), ["rh-bastion"])
	}

	func testCloseTabCallsConfigSinkCleanupWhenSshConfigURLNonNil() throws {
		let bastion = host("bastion", "rh-bastion", cred: .agent)
		let target = host("target", "rh-target", jump: "rh-bastion")
		let sink = InMemorySSHConfigSink()
		let store = SessionStore.makeForTest(hosts: [bastion, target], configSink: sink)
		let tabId = store.openTab(host: target)
		store.setSSHConfigURLForTest(URL(string: "tmpfs:///0")!, tabId: tabId)
		store.closeTab(tabId: tabId)
		XCTAssertEqual(sink.cleanups, [URL(string: "tmpfs:///0")!])
	}

	func testSurfaceConfigForChainedTabUsesChainCommandShape() throws {
		// Pin the regression: surfaceConfig MUST reflect the chain command,
		// not the direct-path command that ignores the jump-host config.
		let bastion = host("bastion", "rh-bastion", cred: .agent)
		let target = host("target", "rh-target", jump: "rh-bastion")
		let sink = InMemorySSHConfigSink()
		let store = SessionStore.makeForTest(hosts: [bastion, target], configSink: sink)
		let tabId = store.openTab(host: target)
		// Populate connectionOutput via the test seam (simulates runConnection success).
		store.populateChainOutputForTest(tabId: tabId)

		guard let cfg = store.surfaceConfig(for: tabId) else {
			return XCTFail("surfaceConfig must return non-nil for chained tab")
		}
		XCTAssertTrue(cfg.command.contains("-F "),
		              "surfaceConfig command must use -F <configPath> for chained tab; got: \(cfg.command)")
		XCTAssertTrue(cfg.command.contains("caterm-h-\(target.id.uuidString)"),
		              "surfaceConfig command must use the target alias; got: \(cfg.command)")
		XCTAssertTrue(cfg.env.contains { $0.0 == "CATERM_CHAIN" },
		              "surfaceConfig env must contain CATERM_CHAIN")
	}

	func testSurfaceConfigForChainedTabRespectsInstallTerminfoFromBuild() throws {
		// Pin the I-1 regression: installTerminfo=true on chain build must
		// produce a command with terminfo wrapping (e.g., contains TERM=xterm-ghostty).
		let bastion = host("bastion", "rh-bastion", cred: .agent)
		let target = host("target", "rh-target", jump: "rh-bastion")
		let sink = InMemorySSHConfigSink()
		let store = SessionStore.makeForTest(hosts: [bastion, target], configSink: sink)
		let tabId = store.openTab(host: target)
		// Synthesize a chain build with installTerminfo=true.
		store.populateChainOutputForTest(tabId: tabId, installTerminfo: true)

		let cfg = store.surfaceConfig(for: tabId)
		XCTAssertNotNil(cfg)
		// Terminfo wrapping is identifiable by `TERM=xterm-ghostty` in the env.
		XCTAssertTrue(cfg!.env.contains(where: { $0.0 == "TERM" && $0.1 == "xterm-ghostty" }),
		              "chained tab with installTerminfo=true must have TERM=xterm-ghostty env; got: \(cfg!.env)")
		// The command must contain the `-t` flag (PTY allocation) that the
		// terminfo install wrapper requires, confirming wrapping is active.
		XCTAssertTrue(cfg!.command.contains(" -t "),
		              "chained tab with installTerminfo=true must have -t flag in command; got: \(cfg!.command)")
		// The command must also contain the infocmp check that is the outer
		// guard of the install wrapper.
		XCTAssertTrue(cfg!.command.contains("infocmp xterm-ghostty"),
		              "chained tab with installTerminfo=true must have terminfo wrap in command; got: \(cfg!.command)")
	}

	func testRetryTabCleansOldSshConfigURL() throws {
		// Pin the regression: retryTab must clean the prior sshConfigURL before
		// starting a fresh connection, otherwise the old temp file is leaked.
		let bastion = host("bastion", "rh-bastion", cred: .agent)
		let target = host("target", "rh-target", jump: "rh-bastion")
		let sink = InMemorySSHConfigSink()
		let store = SessionStore.makeForTest(hosts: [bastion, target], configSink: sink)
		let tabId = store.openTab(host: target)
		// Inject a fake configURL to simulate a prior successful attempt.
		store.setSSHConfigURLForTest(URL(string: "tmpfs:///0")!, tabId: tabId)
		store.retryTab(tabId: tabId)
		XCTAssertEqual(sink.cleanups, [URL(string: "tmpfs:///0")!],
		               "retryTab must clean the prior sshConfigURL before restarting")
	}
}
