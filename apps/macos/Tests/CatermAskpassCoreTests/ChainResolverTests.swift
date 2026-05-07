import XCTest
@testable import CatermAskpassCore

final class ChainResolverTests: XCTestCase {
	private func entry(host: String, user: String = "u",
	                   port: Int = 22, hostId: String = "id-1",
	                   alias: String? = nil,
	                   keyPath: String? = nil) -> AskpassChainEntry {
		AskpassChainEntry(
			hostId: hostId,
			alias: alias ?? "caterm-h-\(hostId)",
			user: user,
			hostname: host,
			port: port,
			keyPath: keyPath
		)
	}

	func testPasswordPromptNoPortSingleCandidate() {
		let chain = [entry(host: "bastion.example.com", hostId: "id-1")]
		let r = resolveAskpassPrompt("u@bastion.example.com's password: ",
		                             chain: chain)
		XCTAssertEqual(r, .found(.password(hostId: "id-1")))
	}

	func testPasswordPromptWithPortPicksByPort() {
		let chain = [
			entry(host: "h.example.com", port: 22, hostId: "id-22"),
			entry(host: "h.example.com", port: 2222, hostId: "id-2222"),
		]
		let r = resolveAskpassPrompt("u@h.example.com:2222's password: ",
		                             chain: chain)
		XCTAssertEqual(r, .found(.password(hostId: "id-2222")))
	}

	func testPasswordPromptUsesAliasMatch() {
		let chain = [entry(host: "real.example.com",
		                   hostId: "id-1",
		                   alias: "caterm-h-id-1")]
		let r = resolveAskpassPrompt("u@caterm-h-id-1's password: ",
		                             chain: chain)
		XCTAssertEqual(r, .found(.password(hostId: "id-1")))
	}

	func testPasswordPromptAmbiguousByUserHostnameWithoutPort() {
		let chain = [
			entry(host: "h.example.com", port: 22, hostId: "id-22"),
			entry(host: "h.example.com", port: 2222, hostId: "id-2222"),
		]
		let r = resolveAskpassPrompt("u@h.example.com's password: ",
		                             chain: chain)
		XCTAssertEqual(r, .ambiguous)
	}

	func testPasswordPromptNoMatchingUserReturnsNoMatch() {
		let chain = [entry(host: "h.example.com", user: "alice",
		                   hostId: "id-1")]
		let r = resolveAskpassPrompt("bob@h.example.com's password: ",
		                             chain: chain)
		XCTAssertEqual(r, .noMatch)
	}

	func testPassphrasePromptMatchesAbsolutePath() {
		let chain = [entry(host: "h.example.com", hostId: "id-1",
		                   keyPath: "/Users/u/.ssh/key")]
		let r = resolveAskpassPrompt(
			"Enter passphrase for key '/Users/u/.ssh/key': ",
			chain: chain)
		XCTAssertEqual(r, .found(.passphrase(hostId: "id-1")))
	}

	func testPassphrasePromptDoesNotMatchTildePath() {
		let chain = [entry(host: "h.example.com", hostId: "id-1",
		                   keyPath: "/Users/u/.ssh/key")]
		let r = resolveAskpassPrompt(
			"Enter passphrase for key '~/.ssh/key': ",
			chain: chain)
		XCTAssertEqual(r, .noMatch)
	}

	func testUnknownPromptFormatReturnsNoMatch() {
		let chain = [entry(host: "h.example.com", hostId: "id-1")]
		let r = resolveAskpassPrompt("Some other prompt: ", chain: chain)
		XCTAssertEqual(r, .noMatch)
	}

	func testEmptyChainReturnsNoMatchForAnyPrompt() {
		let r = resolveAskpassPrompt("u@h.example.com's password: ",
		                             chain: [])
		XCTAssertEqual(r, .noMatch)
	}
}
