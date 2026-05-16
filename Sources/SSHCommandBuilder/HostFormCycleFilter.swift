import Foundation

/// Picker filter for `HostFormView`'s "Via host" dropdown. Pure function;
/// returns the subset of `allHosts` that can safely be used as
/// `editingHost`'s jump host without creating a cycle.
public enum HostFormCycleFilter {
	public static func eligibleJumpHosts(
		editingHost: SSHHost,
		allHosts: [SSHHost]
	) -> [SSHHost] {
		allHosts.filter { candidate in
			// Rule 1: cannot pick self.
			guard candidate.id != editingHost.id else { return false }
			// Rule 2: candidate's transitive chain must not pass through
			// editingHost. Walk up via local jumpHostId when available,
			// otherwise fall back to jumpHostServerId.
			var visited: Set<UUID> = []
			var cursor: SSHHost? = candidate
			while let cur = cursor {
				if let nextId = cur.jumpHostId {
					if nextId == editingHost.id { return false }
					if visited.contains(nextId) { return false }
					visited.insert(nextId)
					cursor = allHosts.first { $0.id == nextId }
					continue
				}
				if let nextSid = cur.jumpHostServerId {
					if nextSid == editingHost.serverId { return false }
					cursor = allHosts.first { $0.serverId == nextSid }
					continue
				}
				cursor = nil
			}
			return true
		}
	}
}
