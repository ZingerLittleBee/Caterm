import XCTest
@testable import SSHCommandBuilder

final class HostFormCycleFilterTests: XCTestCase {
	private func host(_ name: String, _ serverId: String?,
	                  jump: String? = nil) -> SSHHost {
		var h = SSHHost(name: name, hostname: "\(name).example.com",
		                port: 22, username: "u", credential: .password)
		h.serverId = serverId
		h.jumpHostServerId = jump
		return h
	}

	func testFilterExcludesSelf() {
		let a = host("a", "rh-a")
		let b = host("b", "rh-b")
		let filtered = HostFormCycleFilter.eligibleJumpHosts(
			editingHost: a, allHosts: [a, b])
		XCTAssertEqual(filtered.map(\.name), ["b"])
	}

	func testFilterIncludesUnsyncedHostsWhenTheyDoNotCreateCycles() {
		let a = host("a", "rh-a")
		let b = host("b", nil)            // not synced yet
		let c = host("c", "rh-c")
		let filtered = HostFormCycleFilter.eligibleJumpHosts(
			editingHost: a, allHosts: [a, b, c])
		XCTAssertEqual(Set(filtered.map(\.name)), Set(["b", "c"]))
	}

	func testFilterExcludesHostsWhoseChainPassesThroughEditingHost() {
		// If we're editing `a`, then `b` (whose chain is b → a) cannot be
		// picked as a's jump because that would create a cycle.
		let a = host("a", "rh-a")
		let b = host("b", "rh-b", jump: "rh-a")
		let filtered = HostFormCycleFilter.eligibleJumpHosts(
			editingHost: a, allHosts: [a, b])
		XCTAssertTrue(filtered.isEmpty,
			"b transitively references a so it must be filtered out")
	}

	func testFilterIncludesHostsWithUnrelatedChains() {
		let a = host("a", "rh-a")
		let b = host("b", "rh-b")
		let c = host("c", "rh-c", jump: "rh-b")  // c → b, no a
		let filtered = HostFormCycleFilter.eligibleJumpHosts(
			editingHost: a, allHosts: [a, b, c])
		XCTAssertEqual(Set(filtered.map(\.name)), Set(["b", "c"]))
	}

	func testFilterExcludesCandidateWithServerReferenceCycle() {
		let editing = host("editing", "rh-editing")
		let b = host("b", "rh-b", jump: "rh-c")
		let c = host("c", "rh-c", jump: "rh-b")

		let filtered = HostFormCycleFilter.eligibleJumpHosts(
			editingHost: editing,
			allHosts: [editing, b, c]
		)

		XCTAssertTrue(filtered.isEmpty)
	}

	func testFilterKeepsCandidateWithMissingAncestorForFormDiagnostic() {
		let editing = host("editing", "rh-editing")
		let broken = host("broken", "rh-broken", jump: "rh-deleted")

		let filtered = HostFormCycleFilter.eligibleJumpHosts(
			editingHost: editing,
			allHosts: [editing, broken]
		)

		XCTAssertEqual(filtered.map(\.name), ["broken"])
	}
}
