import XCTest
@testable import SSHCommandBuilder

final class ChainTests: XCTestCase {
	private func host(_ name: String, _ serverId: String?,
	                  jump: String? = nil) -> SSHHost {
		var h = SSHHost(name: name, hostname: "\(name).example.com",
		                port: 22, username: "u", credential: .password)
		h.serverId = serverId
		h.jumpHostServerId = jump
		return h
	}

	func testNoChainReturnsEmpty() throws {
		let target = host("target", "rh-target")
		XCTAssertEqual(try target.resolvedChain(in: [target]), [])
	}

	func testSingleHopReturnsAncestor() throws {
		let bastion = host("bastion", "rh-bastion")
		let target = host("target", "rh-target", jump: "rh-bastion")
		let chain = try target.resolvedChain(in: [bastion, target])
		XCTAssertEqual(chain.map(\.name), ["bastion"])
	}

	func testMultiHopReturnsAncestorsInDialOrder() throws {
		// Connect order: deep → mid → target.
		// Chain config: target.jump = mid; mid.jump = deep.
		// resolvedChain returns [deep, mid] (target is excluded).
		let deep = host("deep", "rh-deep")
		let mid = host("mid", "rh-mid", jump: "rh-deep")
		let target = host("target", "rh-target", jump: "rh-mid")
		let chain = try target.resolvedChain(in: [deep, mid, target])
		XCTAssertEqual(chain.map(\.name), ["deep", "mid"])
	}

	func testMissingHostThrows() {
		let target = host("target", "rh-target", jump: "rh-ghost")
		XCTAssertThrowsError(try target.resolvedChain(in: [target])) { error in
			guard case ChainResolutionError.missingHost(let id) =
				error as? ChainResolutionError ?? .missingHost(serverId: "")
			else { return XCTFail("wrong error: \(error)") }
			XCTAssertEqual(id, "rh-ghost")
		}
	}

	func testSelfLoopThrows() {
		let target = host("target", "rh-target", jump: "rh-target")
		XCTAssertThrowsError(try target.resolvedChain(in: [target])) { error in
			guard case ChainResolutionError.cycle(let id) =
				error as? ChainResolutionError ?? .cycle(involvingServerId: "")
			else { return XCTFail("wrong error: \(error)") }
			XCTAssertEqual(id, "rh-target")
		}
	}

	func testTwoHostCycleThrows() {
		let a = host("a", "rh-a", jump: "rh-b")
		let b = host("b", "rh-b", jump: "rh-a")
		XCTAssertThrowsError(try a.resolvedChain(in: [a, b]))
	}

	func testFirstHopAddressOnDirectHostReturnsSelf() {
		let target = host("target", "rh-target")
		let addr = target.firstHopAddress(in: [target])
		XCTAssertEqual(addr?.hostname, "target.example.com")
		XCTAssertEqual(addr?.port, 22)
	}

	func testFirstHopAddressOnChainReturnsDeepestAncestor() {
		let deep = host("deep", "rh-deep")
		let mid = host("mid", "rh-mid", jump: "rh-deep")
		let target = host("target", "rh-target", jump: "rh-mid")
		let addr = target.firstHopAddress(in: [deep, mid, target])
		XCTAssertEqual(addr?.hostname, "deep.example.com")
	}

	func testFirstHopAddressOnBrokenChainReturnsNil() {
		let target = host("target", "rh-target", jump: "rh-ghost")
		XCTAssertNil(target.firstHopAddress(in: [target]))
	}
}
