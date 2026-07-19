import Foundation

/// Picker filter for `HostFormView`'s "Via host" dropdown. Pure function;
/// returns the subset of `allHosts` that can safely be used as
/// `editingHost`'s jump host without creating a cycle.
public enum HostFormCycleFilter {
	public static func eligibleJumpHosts(
		editingHost: SSHHost,
		allHosts: [SSHHost]
	) -> [SSHHost] {
		let resolver = ChainResolver(hosts: allHosts)
		return allHosts.filter { candidate in
			guard candidate.id != editingHost.id else { return false }
			var proposedHost = editingHost
			proposedHost.jumpHostId = candidate.id
			proposedHost.jumpHostServerId = candidate.serverId
			switch resolver.resolve(proposedHost).diagnostic {
			case .cycle:
				return false
			case .missing, .none:
				return true
			}
		}
	}
}
