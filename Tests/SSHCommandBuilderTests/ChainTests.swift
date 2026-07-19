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

	private func localHost(_ name: String, jumpId: UUID? = nil) -> SSHHost {
		var h = SSHHost(name: name, hostname: "\(name).example.com",
		                port: 22, username: "u", credential: .password)
		h.jumpHostId = jumpId
		return h
	}

	func testNoChainReturnsEmpty() {
		let target = host("target", "rh-target")
		let resolution = target.chainResolution(in: [target])
		XCTAssertEqual(resolution.connectionOrder, [])
		XCTAssertNil(resolution.diagnostic)
	}

	func testSingleHopReturnsAncestor() {
		let bastion = host("bastion", "rh-bastion")
		let target = host("target", "rh-target", jump: "rh-bastion")
		let chain = target.chainResolution(in: [bastion, target]).connectionOrder
		XCTAssertEqual(chain.map(\.name), ["bastion"])
	}

	func testSingleHopResolvesUnsyncedAncestorByLocalId() {
		let bastion = localHost("bastion")
		var target = localHost("target")
		target.jumpHostId = bastion.id

		let chain = target.chainResolution(in: [bastion, target]).connectionOrder
		XCTAssertEqual(chain.map(\.name), ["bastion"])
	}

	func testMissingLocalReferenceReturnsTypedDiagnostic() {
		let missingID = UUID()
		let target = localHost("target", jumpId: missingID)

		XCTAssertEqual(
			target.chainResolution(in: [target]).diagnostic,
			.missing(reference: .localID(missingID))
		)
	}

	func testMissingLocalReferenceFallsBackToStableServerReference() {
		let bastion = host("bastion", "rh-bastion")
		var target = localHost("target", jumpId: UUID())
		target.jumpHostServerId = bastion.serverId

		let resolution = target.chainResolution(in: [bastion, target])

		XCTAssertEqual(resolution.connectionOrder.map(\.name), ["bastion"])
		XCTAssertNil(resolution.diagnostic)
	}

	func testValidLocalReferenceWinsOverDifferentServerReference() {
		let localParent = localHost("local-parent")
		let serverParent = host("server-parent", "rh-server-parent")
		var target = localHost("target", jumpId: localParent.id)
		target.jumpHostServerId = serverParent.serverId

		let resolution = target.chainResolution(
			in: [localParent, serverParent, target]
		)

		XCTAssertEqual(resolution.ancestors.map(\.id), [localParent.id])
		XCTAssertNil(resolution.diagnostic)
	}

	func testMultiHopChainSupportsMixedLocalAndServerReferences() {
		let deep = localHost("deep")
		var mid = host("mid", "rh-mid")
		mid.jumpHostId = deep.id
		let target = host("target", "rh-target", jump: "rh-mid")

		let resolution = target.chainResolution(in: [deep, mid, target])

		XCTAssertEqual(resolution.ancestors.map(\.name), ["mid", "deep"])
		XCTAssertEqual(resolution.connectionOrder.map(\.name), ["deep", "mid"])
		XCTAssertNil(resolution.diagnostic)
	}

	func testMultiHopReturnsAncestorsInDialOrder() {
		// Connect order: deep → mid → target.
		// Chain config: target.jump = mid; mid.jump = deep.
		// connectionOrder returns [deep, mid] (target is excluded).
		let deep = host("deep", "rh-deep")
		let mid = host("mid", "rh-mid", jump: "rh-deep")
		let target = host("target", "rh-target", jump: "rh-mid")
		let chain = target.chainResolution(in: [deep, mid, target]).connectionOrder
		XCTAssertEqual(chain.map(\.name), ["deep", "mid"])
	}

	func testResolutionExposesTraversalAndConnectionOrder() {
		let deep = host("deep", "rh-deep")
		let mid = host("mid", "rh-mid", jump: "rh-deep")
		let target = host("target", "rh-target", jump: "rh-mid")

		let resolution = target.chainResolution(in: [deep, mid, target])

		XCTAssertEqual(resolution.ancestors.map(\.name), ["mid", "deep"])
		XCTAssertEqual(resolution.connectionOrder.map(\.name), ["deep", "mid"])
		XCTAssertNil(resolution.diagnostic)
	}

	func testResolutionReturnsPrefixAndMissingReferenceDiagnostic() {
		let mid = host("mid", "rh-mid", jump: "rh-ghost")
		let target = host("target", "rh-target", jump: "rh-mid")

		let resolution = target.chainResolution(in: [mid, target])

		XCTAssertEqual(resolution.ancestors.map(\.name), ["mid"])
		XCTAssertEqual(
			resolution.diagnostic,
			.missing(reference: .serverID("rh-ghost"))
		)
	}

	func testResolutionReturnsPrefixAndCycleDiagnosticWithoutRepeatingNode() {
		let b = host("b", "rh-b", jump: "rh-c")
		let c = host("c", "rh-c", jump: "rh-b")
		let target = host("target", "rh-target", jump: "rh-b")

		let resolution = target.chainResolution(in: [b, c, target])

		XCTAssertEqual(resolution.ancestors.map(\.name), ["b", "c"])
		XCTAssertEqual(
			resolution.diagnostic,
			.cycle(reference: .serverID("rh-b"))
		)
	}

	func testMissingHostReturnsDiagnostic() {
		let target = host("target", "rh-target", jump: "rh-ghost")
		XCTAssertEqual(
			target.chainResolution(in: [target]).diagnostic,
			.missing(reference: .serverID("rh-ghost"))
		)
	}

	func testSelfLoopReturnsCycleDiagnostic() {
		let target = host("target", "rh-target", jump: "rh-target")
		XCTAssertEqual(
			target.chainResolution(in: [target]).diagnostic,
			.cycle(reference: .serverID("rh-target"))
		)
	}

	func testTwoHostCycleReturnsDiagnostic() {
		let a = host("a", "rh-a", jump: "rh-b")
		let b = host("b", "rh-b", jump: "rh-a")
		XCTAssertEqual(
			a.chainResolution(in: [a, b]).diagnostic,
			.cycle(reference: .serverID("rh-a"))
		)
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

	func testFirstHopAddressUsesUnsyncedLocalAncestor() {
		let bastion = localHost("bastion")
		var target = localHost("target")
		target.jumpHostId = bastion.id

		let addr = target.firstHopAddress(in: [bastion, target])
		XCTAssertEqual(addr?.hostname, "bastion.example.com")
		XCTAssertEqual(addr?.port, 22)
	}

	func testFirstHopAddressOnBrokenChainReturnsNil() {
		let target = host("target", "rh-target", jump: "rh-ghost")
		XCTAssertNil(target.firstHopAddress(in: [target]))
	}
}
