import Foundation
import SSHCommandBuilder

enum HostSearch {
	static func filter(_ hosts: [SSHHost], query: String) -> [SSHHost] {
		let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return hosts }
		return hosts.filter { host in
			let destination = "\(host.username)@\(host.hostname)"
			let searchableValues = [
				host.name,
				host.hostname,
				host.username,
				String(host.port),
				destination,
				"\(host.hostname):\(host.port)",
				"\(destination):\(host.port)",
				host.organization.groupPath.joined(separator: " "),
			] + host.organization.tags
			return searchableValues.contains {
				$0.localizedCaseInsensitiveContains(query)
			}
		}
	}
}
