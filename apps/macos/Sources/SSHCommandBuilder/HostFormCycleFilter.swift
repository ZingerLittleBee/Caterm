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
			// Rule 2: must be synced (have a serverId).
			guard candidate.serverId != nil else { return false }
			// Rule 3: candidate's transitive chain must not pass through
			// editingHost. Walk up via jumpHostServerId, lookup by serverId.
			var visited: Set<String> = []
			var cursor: SSHHost? = candidate
			while let cur = cursor, let nextSid = cur.jumpHostServerId {
				if nextSid == editingHost.serverId { return false }
				if visited.contains(nextSid) { return false }
				visited.insert(nextSid)
				cursor = allHosts.first { $0.serverId == nextSid }
			}
			return true
		}
	}
}
