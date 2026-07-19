/// Indexes local entities by device-local identity and cross-device server
/// identity. Matching always prefers the local ID before the server ID.
public struct MergeIdentityIndex<Entity, LocalID: Hashable, ServerID: Hashable> {
	private var byLocalID: [LocalID: Entity] = [:]
	private var byServerID: [ServerID: Entity] = [:]

	public init(
		_ entities: [Entity],
		localID: (Entity) -> LocalID,
		serverID: (Entity) -> ServerID?
	) {
		for entity in entities {
			let id = localID(entity)
			if byLocalID[id] == nil {
				byLocalID[id] = entity
			}
			if let id = serverID(entity), byServerID[id] == nil {
				byServerID[id] = entity
			}
		}
	}

	public func match(
		localID: LocalID?,
		serverID: ServerID?
	) -> Entity? {
		if let localID, let entity = byLocalID[localID] {
			return entity
		}
		if let serverID, let entity = byServerID[serverID] {
			return entity
		}
		return nil
	}
}
