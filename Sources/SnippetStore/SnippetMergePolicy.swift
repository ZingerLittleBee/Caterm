import Foundation
import MergeDecision
import SnippetSyncClient

enum SnippetMergePolicy {
	typealias IdentityIndex = MergeIdentityIndex<Snippet, UUID, String>

	static func makeIdentityIndex(_ snippets: [Snippet]) -> IdentityIndex {
		IdentityIndex(
			snippets,
			localID: { $0.id },
			serverID: { _ in nil }
		)
	}

	static func match(
		_ incoming: Snippet,
		in index: IdentityIndex
	) -> Snippet? {
		index.match(
			localID: incoming.id,
			serverID: nil
		)
	}

	static func decide(
		local: Snippet,
		incoming: Snippet
	) -> MergeDecision {
		MergePolicy<Snippet, Snippet>(
			local: { $0.revision },
			incoming: { $0.revision }
		)
		.thenOptional(
			local: { $0.metadataUpdatedAt },
			incoming: { $0.metadataUpdatedAt }
		)
		.then(
			local: { $0.updatedAt },
			incoming: { $0.updatedAt }
		)
		.resolvingTies { local, incoming in
			// Equal version fields but different cloud metadata or payload use
			// the incoming canonical copy so both sync paths converge.
			local == incoming ? .equivalent : .incoming
		}
		.decide(local: local, incoming: incoming)
	}
}
