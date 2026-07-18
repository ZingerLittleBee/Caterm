import Foundation
import XCTest
@testable import MergeDecision

final class MergePolicyTests: XCTestCase {
	private struct Local {
		let id: Int
		let serverID: String?
		let revision: Int
		let metadataDate: Date?
		let content: String
	}

	private struct Incoming {
		let revision: Int
		let metadataDate: Date?
		let content: String
	}

	func test_identityMatchPrefersLocalIDOverServerID() throws {
		let byLocalID = Local(
			id: 1,
			serverID: "server-a",
			revision: 0,
			metadataDate: nil,
			content: "local-id"
		)
		let byServerID = Local(
			id: 2,
			serverID: "server-b",
			revision: 0,
			metadataDate: nil,
			content: "server-id"
		)
		let index = MergeIdentityIndex(
			[byLocalID, byServerID],
			localID: { $0.id },
			serverID: { $0.serverID }
		)

		let match = try XCTUnwrap(index.match(localID: 1, serverID: "server-b"))

		XCTAssertEqual(match.content, "local-id")
	}

	func test_identityMatchFallsBackToServerID() throws {
		let local = Local(
			id: 1,
			serverID: "server-a",
			revision: 0,
			metadataDate: nil,
			content: "matched"
		)
		let index = MergeIdentityIndex(
			[local],
			localID: { $0.id },
			serverID: { $0.serverID }
		)

		let match = try XCTUnwrap(index.match(localID: 9, serverID: "server-a"))

		XCTAssertEqual(match.content, "matched")
	}

	func test_identityMatchReturnsNilWithoutEitherIdentity() {
		let local = Local(
			id: 1,
			serverID: "server-a",
			revision: 0,
			metadataDate: nil,
			content: "local"
		)
		let index = MergeIdentityIndex(
			[local],
			localID: { $0.id },
			serverID: { $0.serverID }
		)

		XCTAssertNil(index.match(localID: 2, serverID: "server-b"))
	}

	func test_policyUsesFirstDecisiveRule() {
		let policy = MergePolicy<Local, Incoming>(
			local: { $0.revision },
			incoming: { $0.revision }
		)
		.thenOptional(
			local: { $0.metadataDate },
			incoming: { $0.metadataDate }
		)
		.resolvingTies { local, incoming in
			local.content == incoming.content ? .equivalent : .incoming
		}
		let local = Local(
			id: 1,
			serverID: nil,
			revision: 2,
			metadataDate: nil,
			content: "local"
		)
		let incoming = Incoming(
			revision: 1,
			metadataDate: Date.distantFuture,
			content: "incoming"
		)

		XCTAssertEqual(policy.decide(local: local, incoming: incoming), .local)
	}

	func test_policyUsesOptionalPresenceThenTieBreaker() {
		let policy = MergePolicy<Local, Incoming>(
			local: { $0.revision },
			incoming: { $0.revision }
		)
		.thenOptional(
			local: { $0.metadataDate },
			incoming: { $0.metadataDate }
		)
		.resolvingTies { local, incoming in
			local.content == incoming.content ? .equivalent : .incoming
		}
		let local = Local(
			id: 1,
			serverID: nil,
			revision: 1,
			metadataDate: nil,
			content: "same"
		)

		XCTAssertEqual(
			policy.decide(
				local: local,
				incoming: Incoming(
					revision: 1,
					metadataDate: Date.distantPast,
					content: "same"
				)
			),
			.incoming
		)
		XCTAssertEqual(
			policy.decide(
				local: local,
				incoming: Incoming(
					revision: 1,
					metadataDate: nil,
					content: "different"
				)
			),
			.incoming
		)
	}
}
