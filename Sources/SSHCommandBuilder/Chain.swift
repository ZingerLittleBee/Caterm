import Foundation

public struct ChainResolution: Equatable {
	public enum Reference: Equatable {
		case localID(UUID)
		case serverID(String)
	}

	public enum Diagnostic: Equatable {
		case missing(reference: Reference)
		case cycle(reference: Reference)
	}

	/// Ancestors in traversal order: direct parent, grandparent, and so on.
	public let ancestors: [SSHHost]
	public let diagnostic: Diagnostic?

	/// Ancestors in the order SSH must connect to them.
	public var connectionOrder: [SSHHost] {
		Array(ancestors.reversed())
	}

	public var isComplete: Bool { diagnostic == nil }
}

/// Resolves jump-host graphs against one indexed host snapshot.
public struct ChainResolver {
	private let hostsByLocalID: [UUID: SSHHost]
	private let hostsByServerID: [String: SSHHost]

	public init(hosts: [SSHHost]) {
		var hostsByLocalID: [UUID: SSHHost] = [:]
		var hostsByServerID: [String: SSHHost] = [:]
		for host in hosts {
			hostsByLocalID[host.id] = host
			if let serverID = host.serverId, hostsByServerID[serverID] == nil {
				hostsByServerID[serverID] = host
			}
		}
		self.hostsByLocalID = hostsByLocalID
		self.hostsByServerID = hostsByServerID
	}

	/// Preserves the valid prefix and returns a diagnostic when traversal
	/// cannot continue.
	public func resolve(_ host: SSHHost) -> ChainResolution {
		var ancestors: [SSHHost] = []
		var visitedHostIDs: Set<UUID> = [host.id]
		var cursor = host
		while let next = nextJumpStep(from: cursor) {
			switch next {
			case .missing(let reference):
				return ChainResolution(
					ancestors: ancestors,
					diagnostic: .missing(reference: reference)
				)
			case .parent(let reference, let parent):
				guard visitedHostIDs.insert(parent.id).inserted else {
					return ChainResolution(
						ancestors: ancestors,
						diagnostic: .cycle(reference: reference)
					)
				}
				ancestors.append(parent)
				cursor = parent
			}
		}
		return ChainResolution(ancestors: ancestors, diagnostic: nil)
	}

	private func nextJumpStep(from host: SSHHost) -> JumpStep? {
		if let jumpHostID = host.jumpHostId {
			let localReference = ChainResolution.Reference.localID(jumpHostID)
			if let parent = hostsByLocalID[jumpHostID] {
				return .parent(reference: localReference, host: parent)
			}
			if host.jumpHostServerId == nil {
				return .missing(reference: localReference)
			}
		}
		guard let jumpHostServerID = host.jumpHostServerId else { return nil }
		let serverReference = ChainResolution.Reference.serverID(jumpHostServerID)
		guard let parent = hostsByServerID[jumpHostServerID] else {
			return .missing(reference: serverReference)
		}
		return .parent(reference: serverReference, host: parent)
	}
}

public extension SSHHost {
	/// Convenience for one-off resolution. Reuse `ChainResolver` when resolving
	/// multiple hosts against the same snapshot.
	func chainResolution(in hosts: [SSHHost]) -> ChainResolution {
		ChainResolver(hosts: hosts).resolve(self)
	}

	/// First TCP endpoint ssh actually dials — i.e., the deepest
	/// ancestor's `(hostname, port)` when there's a chain, else
	/// `self`'s. Returns nil only when the chain is broken.
	func firstHopAddress(in hosts: [SSHHost]) -> (hostname: String, port: Int)? {
		let resolution = chainResolution(in: hosts)
		guard resolution.isComplete else { return nil }
		if let deepest = resolution.connectionOrder.first {
			return (deepest.hostname, deepest.port)
		}
		return (self.hostname, self.port)
	}

}

private enum JumpStep {
	case parent(reference: ChainResolution.Reference, host: SSHHost)
	case missing(reference: ChainResolution.Reference)
}
