import Foundation

public enum ChainResolutionError: Error, Equatable {
	/// The `jumpHostServerId` references a host that's not in the
	/// in-memory list (deleted, or not yet pulled from CloudKit on
	/// this device).
	case missingHost(serverId: String)

	/// Self-loop or cycle. The associated `serverId` is the first
	/// node revisited.
	case cycle(involvingServerId: String)
}

public extension SSHHost {
	/// Returns the chain ancestors in connect order — index 0 is the
	/// host ssh dials *first* (deepest ancestor); the last entry is
	/// `self`'s direct parent. Returns an empty array when
	/// `jumpHostServerId` is nil. Throws when the chain cycles or
	/// references a host not present in `hosts`.
	func resolvedChain(in hosts: [SSHHost]) throws -> [SSHHost] {
		var ancestors: [SSHHost] = []
		var visited: Set<String> = []
		var cursor = self
		while let nextServerId = cursor.jumpHostServerId {
			// Self-loop check: if the next reference points to self.
			if let selfSid = self.serverId, nextServerId == selfSid {
				throw ChainResolutionError.cycle(involvingServerId: selfSid)
			}
			if visited.contains(nextServerId) {
				throw ChainResolutionError.cycle(involvingServerId: nextServerId)
			}
			guard let parent = hosts.first(where: { $0.serverId == nextServerId }) else {
				throw ChainResolutionError.missingHost(serverId: nextServerId)
			}
			visited.insert(nextServerId)
			ancestors.append(parent)
			cursor = parent
		}
		// `ancestors` is in walk order (parent, grandparent, ...).
		// Spec wants index 0 = deepest ancestor (host ssh dials first).
		return ancestors.reversed()
	}

	/// First TCP endpoint ssh actually dials — i.e., the deepest
	/// ancestor's `(hostname, port)` when there's a chain, else
	/// `self`'s. Returns nil only when the chain is broken.
	func firstHopAddress(in hosts: [SSHHost]) -> (hostname: String, port: Int)? {
		do {
			let chain = try self.resolvedChain(in: hosts)
			if let deepest = chain.first {
				return (deepest.hostname, deepest.port)
			}
			return (self.hostname, self.port)
		} catch {
			return nil
		}
	}
}
