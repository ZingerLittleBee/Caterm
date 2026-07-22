import Foundation

public struct WorkspaceID: Hashable, Sendable, Identifiable, Codable {
	public let rawValue: UUID
	public var id: UUID { rawValue }

	public init(rawValue: UUID = UUID()) {
		self.rawValue = rawValue
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		rawValue = try container.decode(UUID.self)
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}
}

public struct PaneID: Hashable, Sendable, Identifiable, Codable {
	public let rawValue: UUID
	public var id: UUID { rawValue }

	public init(rawValue: UUID = UUID()) {
		self.rawValue = rawValue
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		rawValue = try container.decode(UUID.self)
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}
}

public struct SplitID: Hashable, Sendable, Identifiable, Codable {
	public let rawValue: UUID
	public var id: UUID { rawValue }

	public init(rawValue: UUID = UUID()) {
		self.rawValue = rawValue
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		rawValue = try container.decode(UUID.self)
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}
}

public struct OneTimeConnectionDescriptor: Codable, Hashable, Sendable {
	public enum ValidationError: Swift.Error, Equatable, Sendable {
		case emptyDisplayName
		case emptyHostname
		case invalidPort
		case emptyUsername
	}

	public let displayName: String
	public let hostname: String
	public let port: Int
	public let username: String

	public init(
		displayName: String,
		hostname: String,
		port: Int,
		username: String
	) throws {
		guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw ValidationError.emptyDisplayName
		}
		guard !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw ValidationError.emptyHostname
		}
		guard (1...65_535).contains(port) else {
			throw ValidationError.invalidPort
		}
		guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw ValidationError.emptyUsername
		}
		self.displayName = displayName
		self.hostname = hostname
		self.port = port
		self.username = username
	}

	private enum CodingKeys: String, CodingKey {
		case displayName
		case hostname
		case port
		case username
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		try self.init(
			displayName: container.decode(String.self, forKey: .displayName),
			hostname: container.decode(String.self, forKey: .hostname),
			port: container.decode(Int.self, forKey: .port),
			username: container.decode(String.self, forKey: .username)
		)
	}
}

public enum WorkspaceHostReference: Hashable, Sendable, Codable {
	case saved(id: UUID)
	case oneTime(OneTimeConnectionDescriptor)

	private enum Kind: String, Codable {
		case saved
		case oneTime
	}

	private enum CodingKeys: String, CodingKey {
		case kind
		case savedHostID
		case oneTimeConnection
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		switch try container.decode(Kind.self, forKey: .kind) {
		case .saved:
			self = .saved(id: try container.decode(UUID.self, forKey: .savedHostID))
		case .oneTime:
			self = .oneTime(
				try container.decode(
					OneTimeConnectionDescriptor.self,
					forKey: .oneTimeConnection
				)
			)
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .saved(let id):
			try container.encode(Kind.saved, forKey: .kind)
			try container.encode(id, forKey: .savedHostID)
		case .oneTime(let descriptor):
			try container.encode(Kind.oneTime, forKey: .kind)
			try container.encode(descriptor, forKey: .oneTimeConnection)
		}
	}

	public var displayName: String? {
		switch self {
		case .saved:
			nil
		case .oneTime(let descriptor):
			descriptor.displayName
		}
	}
}

public enum WorkspacePaneContent: Codable, Hashable, Sendable {
	case host(WorkspaceHostReference)
	case hostPicker

	private enum Kind: String, Codable {
		case host
		case hostPicker
	}

	private enum CodingKeys: String, CodingKey {
		case kind
		case host
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		switch try container.decode(Kind.self, forKey: .kind) {
		case .host:
			self = .host(try container.decode(WorkspaceHostReference.self, forKey: .host))
		case .hostPicker:
			self = .hostPicker
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .host(let host):
			try container.encode(Kind.host, forKey: .kind)
			try container.encode(host, forKey: .host)
		case .hostPicker:
			try container.encode(Kind.hostPicker, forKey: .kind)
		}
	}
}

public struct WorkspacePane: Codable, Hashable, Sendable, Identifiable {
	public let id: PaneID
	public let content: WorkspacePaneContent

	public var host: WorkspaceHostReference? {
		guard case .host(let host) = content else { return nil }
		return host
	}

	public init(id: PaneID = PaneID(), host: WorkspaceHostReference) {
		self.id = id
		content = .host(host)
	}

	public init(id: PaneID = PaneID(), content: WorkspacePaneContent) {
		self.id = id
		self.content = content
	}

	private enum CodingKeys: String, CodingKey {
		case id
		case content
		case host
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(PaneID.self, forKey: .id)
		if let content = try container.decodeIfPresent(
			WorkspacePaneContent.self,
			forKey: .content
		) {
			self.content = content
		} else {
			content = .host(
				try container.decode(WorkspaceHostReference.self, forKey: .host)
			)
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(content, forKey: .content)
	}
}

public enum WorkspaceSplitAxis: String, Codable, Hashable, Sendable {
	case horizontal
	case vertical
}

public struct WorkspaceSplit: Codable, Hashable, Sendable, Identifiable {
	public enum ValidationError: Swift.Error, Equatable, Sendable {
		case nonFiniteRatio
	}

	public static let minimumRatio = 0.15
	public static let maximumRatio = 0.85

	public let id: SplitID
	public let axis: WorkspaceSplitAxis
	public let ratio: Double
	public let first: WorkspaceTopology
	public let second: WorkspaceTopology

	public init(
		id: SplitID = SplitID(),
		axis: WorkspaceSplitAxis,
		ratio: Double = 0.5,
		first: WorkspaceTopology,
		second: WorkspaceTopology
	) {
		self.id = id
		self.axis = axis
		self.ratio = ratio.isFinite
			? min(max(ratio, Self.minimumRatio), Self.maximumRatio)
			: 0.5
		self.first = first
		self.second = second
	}

	private enum CodingKeys: String, CodingKey {
		case id
		case axis
		case ratio
		case first
		case second
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let ratio = try container.decode(Double.self, forKey: .ratio)
		guard ratio.isFinite else { throw ValidationError.nonFiniteRatio }
		self.init(
			id: try container.decode(SplitID.self, forKey: .id),
			axis: try container.decode(WorkspaceSplitAxis.self, forKey: .axis),
			ratio: ratio,
			first: try container.decode(WorkspaceTopology.self, forKey: .first),
			second: try container.decode(WorkspaceTopology.self, forKey: .second)
		)
	}
}

public indirect enum WorkspaceTopology: Codable, Hashable, Sendable {
	case pane(WorkspacePane)
	case split(WorkspaceSplit)

	private enum Kind: String, Codable {
		case pane
		case split
	}

	private enum CodingKeys: String, CodingKey {
		case kind
		case pane
		case split
	}

	public var panes: [WorkspacePane] {
		switch self {
		case .pane(let pane):
			[pane]
		case .split(let split):
			split.first.panes + split.second.panes
		}
	}

	public var paneIDs: [PaneID] {
		panes.map(\.id)
	}

	public var paneCount: Int {
		panes.count
	}

	public var splitIDs: [SplitID] {
		switch self {
		case .pane:
			[]
		case .split(let split):
			[split.id] + split.first.splitIDs + split.second.splitIDs
		}
	}

	public var split: WorkspaceSplit? {
		guard case .split(let split) = self else { return nil }
		return split
	}

	public func pane(id paneID: PaneID) -> WorkspacePane? {
		panes.first(where: { $0.id == paneID })
	}

	public func contains(_ paneID: PaneID) -> Bool {
		paneIDs.contains(paneID)
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		switch try container.decode(Kind.self, forKey: .kind) {
		case .pane:
			self = .pane(try container.decode(WorkspacePane.self, forKey: .pane))
		case .split:
			self = .split(try container.decode(WorkspaceSplit.self, forKey: .split))
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .pane(let pane):
			try container.encode(Kind.pane, forKey: .kind)
			try container.encode(pane, forKey: .pane)
		case .split(let split):
			try container.encode(Kind.split, forKey: .kind)
			try container.encode(split, forKey: .split)
		}
	}
}

public enum WorkspacePresentation: String, Codable, Hashable, Sendable {
	case focus
	case split
}

public struct Workspace: Codable, Hashable, Sendable, Identifiable {
	public enum ValidationError: Swift.Error, Equatable, Sendable {
		case unsupportedVersion(Int)
		case duplicatePaneIdentity
		case duplicateSplitIdentity
		case activePaneNotFound
		case versionOneContainsSplitState
	}

	public static let currentVersion = 2

	public let version: Int
	public let id: WorkspaceID
	public let topology: WorkspaceTopology
	public let activePaneID: PaneID
	public let presentation: WorkspacePresentation

	public static func onePane(
		id: WorkspaceID = WorkspaceID(),
		paneID: PaneID = PaneID(),
		host: WorkspaceHostReference,
		presentation: WorkspacePresentation = .split
	) -> Workspace {
		Workspace(
			validatedVersion: currentVersion,
			id: id,
			topology: .pane(WorkspacePane(id: paneID, host: host)),
			activePaneID: paneID,
			presentation: presentation
		)
	}

	public init(
		id: WorkspaceID,
		topology: WorkspaceTopology,
		activePaneID: PaneID,
		presentation: WorkspacePresentation,
		version: Int = Workspace.currentVersion
	) throws {
		try Self.validate(
			version: version,
			topology: topology,
			activePaneID: activePaneID
		)
		self.init(
			validatedVersion: version,
			id: id,
			topology: topology,
			activePaneID: activePaneID,
			presentation: presentation
		)
	}

	init(
		validatedVersion: Int,
		id: WorkspaceID,
		topology: WorkspaceTopology,
		activePaneID: PaneID,
		presentation: WorkspacePresentation
	) {
		version = validatedVersion
		self.id = id
		self.topology = topology
		self.activePaneID = activePaneID
		self.presentation = presentation
	}

	private enum CodingKeys: String, CodingKey {
		case version
		case id
		case topology
		case activePaneID
		case presentation
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let version = try container.decode(Int.self, forKey: .version)
		let topology = try container.decode(WorkspaceTopology.self, forKey: .topology)
		let activePaneID = try container.decode(PaneID.self, forKey: .activePaneID)
		try Self.validate(
			version: version,
			topology: topology,
			activePaneID: activePaneID
		)
		self.init(
			validatedVersion: version,
			id: try container.decode(WorkspaceID.self, forKey: .id),
			topology: topology,
			activePaneID: activePaneID,
			presentation: try container.decode(
				WorkspacePresentation.self,
				forKey: .presentation
			)
		)
	}

	private static func validate(
		version: Int,
		topology: WorkspaceTopology,
		activePaneID: PaneID
	) throws {
		guard (1...currentVersion).contains(version) else {
			throw ValidationError.unsupportedVersion(version)
		}
		let paneIDs = topology.paneIDs
		guard Set(paneIDs).count == paneIDs.count else {
			throw ValidationError.duplicatePaneIdentity
		}
		let splitIDs = topology.splitIDs
		guard Set(splitIDs).count == splitIDs.count else {
			throw ValidationError.duplicateSplitIdentity
		}
		guard topology.contains(activePaneID) else {
			throw ValidationError.activePaneNotFound
		}
		if version == 1 {
			guard splitIDs.isEmpty,
			      topology.panes.allSatisfy({ $0.host != nil }) else {
				throw ValidationError.versionOneContainsSplitState
			}
		}
	}

}

public struct WorkspaceRuntimeMap: Sendable {
	public enum Error: Swift.Error, Equatable, Sendable {
		case paneNotFound
		case paneAlreadyBound
		case sessionAlreadyBound
	}

	private struct PaneAddress: Hashable, Sendable {
		let workspaceID: WorkspaceID
		let paneID: PaneID
	}

	private var sessionsByPane: [PaneAddress: UUID] = [:]
	private var panesBySession: [UUID: PaneAddress] = [:]

	public init() {}

	public mutating func bind(
		sessionID: UUID,
		to paneID: PaneID,
		in workspace: Workspace
	) throws {
		guard workspace.topology.contains(paneID) else {
			throw Error.paneNotFound
		}
		let address = PaneAddress(workspaceID: workspace.id, paneID: paneID)
		guard sessionsByPane[address] == nil else {
			throw Error.paneAlreadyBound
		}
		guard panesBySession[sessionID] == nil else {
			throw Error.sessionAlreadyBound
		}
		sessionsByPane[address] = sessionID
		panesBySession[sessionID] = address
	}

	public func sessionID(for paneID: PaneID, in workspaceID: WorkspaceID) -> UUID? {
		sessionsByPane[PaneAddress(workspaceID: workspaceID, paneID: paneID)]
	}

	@discardableResult
	public mutating func unbind(
		paneID: PaneID,
		in workspaceID: WorkspaceID
	) -> UUID? {
		let address = PaneAddress(workspaceID: workspaceID, paneID: paneID)
		guard let sessionID = sessionsByPane.removeValue(forKey: address) else {
			return nil
		}
		panesBySession.removeValue(forKey: sessionID)
		return sessionID
	}

	@discardableResult
	public mutating func unbind(workspaceID: WorkspaceID) -> [UUID] {
		let addresses = sessionsByPane.keys.filter { $0.workspaceID == workspaceID }
		return addresses.compactMap { address in
			guard let sessionID = sessionsByPane.removeValue(forKey: address) else {
				return nil
			}
			panesBySession.removeValue(forKey: sessionID)
			return sessionID
		}
	}
}

public enum WorkspaceWindowState: Codable, Hashable, Sendable {
	case landing(id: UUID)
	case workspace(Workspace)

	private enum Kind: String, Codable {
		case landing
		case workspace
	}

	private enum CodingKeys: String, CodingKey {
		case kind
		case landingID
		case workspace
	}

	public var workspace: Workspace? {
		guard case .workspace(let workspace) = self else { return nil }
		return workspace
	}

	public var workspaceID: WorkspaceID? {
		workspace?.id
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		switch try container.decode(Kind.self, forKey: .kind) {
		case .landing:
			self = .landing(id: try container.decode(UUID.self, forKey: .landingID))
		case .workspace:
			self = .workspace(try container.decode(Workspace.self, forKey: .workspace))
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .landing(let id):
			try container.encode(Kind.landing, forKey: .kind)
			try container.encode(id, forKey: .landingID)
		case .workspace(let workspace):
			try container.encode(Kind.workspace, forKey: .kind)
			try container.encode(workspace, forKey: .workspace)
		}
	}

	public static func == (lhs: WorkspaceWindowState, rhs: WorkspaceWindowState) -> Bool {
		switch (lhs, rhs) {
		case let (.landing(lhsID), .landing(rhsID)):
			lhsID == rhsID
		case let (.workspace(lhsWorkspace), .workspace(rhsWorkspace)):
			lhsWorkspace.id == rhsWorkspace.id
		case (.landing, .workspace), (.workspace, .landing):
			false
		}
	}

	public func hash(into hasher: inout Hasher) {
		switch self {
		case .landing(let id):
			hasher.combine(0)
			hasher.combine(id)
		case .workspace(let workspace):
			hasher.combine(1)
			hasher.combine(workspace.id)
		}
	}
}
