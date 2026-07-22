import Combine
import Foundation
import WorkspaceCore

public struct WorkspaceTemplateID: Codable, Hashable, Identifiable, Sendable {
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

public enum WorkspaceTemplateError: Error, Equatable, LocalizedError, Sendable {
	case emptyName
	case unsupportedVersion(Int)
	case oneTimeHostNotAllowed
	case emptyPaneNotAllowed
	case duplicatePaneIdentity
	case duplicateSplitIdentity
	case preferredPaneNotFound
	case invalidSplitRatio
	case unexpectedField(String)
	case templateNotFound
	case persistence(String)

	public var errorDescription: String? {
		switch self {
		case .emptyName:
			"Enter a name for the Workspace template."
		case .unsupportedVersion(let version):
			"Workspace template version \(version) is not supported."
		case .oneTimeHostNotAllowed:
			"One-time connections cannot be saved in a Workspace template."
		case .emptyPaneNotAllowed:
			"Choose a saved Host for every Pane before saving this Workspace."
		case .duplicatePaneIdentity, .duplicateSplitIdentity, .preferredPaneNotFound,
		     .invalidSplitRatio, .unexpectedField:
			"The Workspace template is invalid."
		case .templateNotFound:
			"The Workspace template no longer exists."
		case .persistence(let message):
			"The Workspace template could not be saved: \(message)"
		}
	}
}

public struct WorkspaceTemplatePane: Codable, Hashable, Identifiable, Sendable {
	public let id: PaneID
	public let savedHostID: UUID

	public init(id: PaneID = PaneID(), savedHostID: UUID) {
		self.id = id
		self.savedHostID = savedHostID
	}

	private enum CodingKeys: String, CodingKey {
		case id
		case savedHostID
	}

	public init(from decoder: Decoder) throws {
		try rejectUnexpectedKeys(from: decoder, allowed: ["id", "savedHostID"])
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(PaneID.self, forKey: .id)
		savedHostID = try container.decode(UUID.self, forKey: .savedHostID)
	}
}

public struct WorkspaceTemplateSplit: Codable, Hashable, Identifiable, Sendable {
	public let id: SplitID
	public let axis: WorkspaceSplitAxis
	public let ratio: Double
	public let first: WorkspaceTemplateTopology
	public let second: WorkspaceTemplateTopology

	public init(
		id: SplitID = SplitID(),
		axis: WorkspaceSplitAxis,
		ratio: Double,
		first: WorkspaceTemplateTopology,
		second: WorkspaceTemplateTopology
	) throws {
		guard ratio.isFinite,
		      (WorkspaceSplit.minimumRatio...WorkspaceSplit.maximumRatio).contains(ratio) else {
			throw WorkspaceTemplateError.invalidSplitRatio
		}
		self.id = id
		self.axis = axis
		self.ratio = ratio
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
		try rejectUnexpectedKeys(
			from: decoder,
			allowed: ["id", "axis", "ratio", "first", "second"]
		)
		let container = try decoder.container(keyedBy: CodingKeys.self)
		try self.init(
			id: container.decode(SplitID.self, forKey: .id),
			axis: container.decode(WorkspaceSplitAxis.self, forKey: .axis),
			ratio: container.decode(Double.self, forKey: .ratio),
			first: container.decode(WorkspaceTemplateTopology.self, forKey: .first),
			second: container.decode(WorkspaceTemplateTopology.self, forKey: .second)
		)
	}
}

public indirect enum WorkspaceTemplateTopology: Codable, Hashable, Sendable {
	case pane(WorkspaceTemplatePane)
	case split(WorkspaceTemplateSplit)

	private enum Kind: String, Codable {
		case pane
		case split
	}

	private enum CodingKeys: String, CodingKey {
		case kind
		case pane
		case split
	}

	public var panes: [WorkspaceTemplatePane] {
		switch self {
		case .pane(let pane):
			[pane]
		case .split(let split):
			split.first.panes + split.second.panes
		}
	}

	public var paneIDs: [PaneID] { panes.map(\.id) }

	public var splitIDs: [SplitID] {
		switch self {
		case .pane:
			[]
		case .split(let split):
			[split.id] + split.first.splitIDs + split.second.splitIDs
		}
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let kind = try container.decode(Kind.self, forKey: .kind)
		switch kind {
		case .pane:
			try rejectUnexpectedKeys(from: decoder, allowed: ["kind", "pane"])
			self = .pane(try container.decode(WorkspaceTemplatePane.self, forKey: .pane))
		case .split:
			try rejectUnexpectedKeys(from: decoder, allowed: ["kind", "split"])
			self = .split(try container.decode(WorkspaceTemplateSplit.self, forKey: .split))
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

public enum WorkspaceTemplateHostAvailability: String, Codable, Hashable, Sendable {
	case available
	case missing
}

public struct WorkspaceTemplatePaneResolution: Hashable, Sendable {
	public let paneID: PaneID
	public let savedHostID: UUID
	public let availability: WorkspaceTemplateHostAvailability
}

public struct WorkspaceTemplateInstantiation: Hashable, Sendable {
	public let workspace: Workspace
	public let resolutions: [WorkspaceTemplatePaneResolution]
}

public struct WorkspaceTemplate: Codable, Hashable, Identifiable, Sendable {
	public static let currentVersion = 2

	public let version: Int
	public let id: WorkspaceTemplateID
	public let name: String
	public let topology: WorkspaceTemplateTopology
	public let preferredPaneID: PaneID
	public let initialPresentation: WorkspacePresentation

	public init(
		workspace: Workspace,
		name: String,
		id: WorkspaceTemplateID = WorkspaceTemplateID()
	) throws {
		let topology = try Self.capture(workspace.topology)
		try self.init(
			version: Self.currentVersion,
			id: id,
			name: name,
			topology: topology,
			preferredPaneID: workspace.activePaneID,
			initialPresentation: workspace.presentation
		)
	}

	private init(
		version: Int,
		id: WorkspaceTemplateID,
		name: String,
		topology: WorkspaceTemplateTopology,
		preferredPaneID: PaneID,
		initialPresentation: WorkspacePresentation
	) throws {
		let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !normalizedName.isEmpty else { throw WorkspaceTemplateError.emptyName }
		guard version == Self.currentVersion else {
			throw WorkspaceTemplateError.unsupportedVersion(version)
		}
		try Self.validate(topology: topology, preferredPaneID: preferredPaneID)
		self.version = Self.currentVersion
		self.id = id
		self.name = normalizedName
		self.topology = topology
		self.preferredPaneID = preferredPaneID
		self.initialPresentation = initialPresentation
	}

	public func instantiate(
		availableHostIDs: Set<UUID>
	) throws -> WorkspaceTemplateInstantiation {
		var paneMap: [PaneID: PaneID] = [:]
		var resolutions: [WorkspaceTemplatePaneResolution] = []
		let workspaceTopology = Self.instantiate(
			topology,
			availableHostIDs: availableHostIDs,
			paneMap: &paneMap,
			resolutions: &resolutions
		)
		guard let activePaneID = paneMap[preferredPaneID] else {
			throw WorkspaceTemplateError.preferredPaneNotFound
		}
		let workspace = try Workspace(
			id: WorkspaceID(),
			topology: workspaceTopology,
			activePaneID: activePaneID,
			presentation: initialPresentation
		)
		return WorkspaceTemplateInstantiation(
			workspace: workspace,
			resolutions: resolutions
		)
	}

	func renamed(to name: String) throws -> WorkspaceTemplate {
		try WorkspaceTemplate(
			version: Self.currentVersion,
			id: id,
			name: name,
			topology: topology,
			preferredPaneID: preferredPaneID,
			initialPresentation: initialPresentation
		)
	}

	func duplicated(name: String) throws -> WorkspaceTemplate {
		try WorkspaceTemplate(
			version: Self.currentVersion,
			id: WorkspaceTemplateID(),
			name: name,
			topology: topology,
			preferredPaneID: preferredPaneID,
			initialPresentation: initialPresentation
		)
	}

	private enum CodingKeys: String, CodingKey {
		case version
		case id
		case name
		case topology
		case preferredPaneID
		case initialPresentation
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let decodedVersion = try container.decode(Int.self, forKey: .version)
		guard (1...Self.currentVersion).contains(decodedVersion) else {
			throw WorkspaceTemplateError.unsupportedVersion(decodedVersion)
		}
		let allowedKeys: Set<String> = decodedVersion == 1
			? ["version", "id", "name", "topology"]
			: [
				"version", "id", "name", "topology", "preferredPaneID",
				"initialPresentation",
			]
		try rejectUnexpectedKeys(from: decoder, allowed: allowedKeys)
		let topology = try container.decode(WorkspaceTemplateTopology.self, forKey: .topology)
		let preferredPaneID: PaneID
		let initialPresentation: WorkspacePresentation
		if decodedVersion == 1 {
			guard let firstPaneID = topology.panes.first?.id else {
				throw WorkspaceTemplateError.preferredPaneNotFound
			}
			preferredPaneID = firstPaneID
			initialPresentation = .split
		} else {
			preferredPaneID = try container.decode(PaneID.self, forKey: .preferredPaneID)
			initialPresentation = try container.decode(
				WorkspacePresentation.self,
				forKey: .initialPresentation
			)
		}
		try self.init(
			version: Self.currentVersion,
			id: container.decode(WorkspaceTemplateID.self, forKey: .id),
			name: container.decode(String.self, forKey: .name),
			topology: topology,
			preferredPaneID: preferredPaneID,
			initialPresentation: initialPresentation
		)
	}

	private static func capture(
		_ topology: WorkspaceTopology
	) throws -> WorkspaceTemplateTopology {
		switch topology {
		case .pane(let pane):
			guard let host = pane.host else {
				throw WorkspaceTemplateError.emptyPaneNotAllowed
			}
			switch host {
			case .saved(let id):
				return .pane(WorkspaceTemplatePane(id: pane.id, savedHostID: id))
			case .oneTime:
				throw WorkspaceTemplateError.oneTimeHostNotAllowed
			}
		case .split(let split):
			return .split(try WorkspaceTemplateSplit(
				id: split.id,
				axis: split.axis,
				ratio: split.ratio,
				first: capture(split.first),
				second: capture(split.second)
			))
		}
	}

	private static func instantiate(
		_ topology: WorkspaceTemplateTopology,
		availableHostIDs: Set<UUID>,
		paneMap: inout [PaneID: PaneID],
		resolutions: inout [WorkspaceTemplatePaneResolution]
	) -> WorkspaceTopology {
		switch topology {
		case .pane(let templatePane):
			let paneID = PaneID()
			paneMap[templatePane.id] = paneID
			resolutions.append(WorkspaceTemplatePaneResolution(
				paneID: paneID,
				savedHostID: templatePane.savedHostID,
				availability: availableHostIDs.contains(templatePane.savedHostID)
					? .available
					: .missing
			))
			return .pane(WorkspacePane(
				id: paneID,
				host: .saved(id: templatePane.savedHostID)
			))
		case .split(let templateSplit):
			let first = instantiate(
				templateSplit.first,
				availableHostIDs: availableHostIDs,
				paneMap: &paneMap,
				resolutions: &resolutions
			)
			let second = instantiate(
				templateSplit.second,
				availableHostIDs: availableHostIDs,
				paneMap: &paneMap,
				resolutions: &resolutions
			)
			return .split(WorkspaceSplit(
				id: SplitID(),
				axis: templateSplit.axis,
				ratio: templateSplit.ratio,
				first: first,
				second: second
			))
		}
	}

	private static func validate(
		topology: WorkspaceTemplateTopology,
		preferredPaneID: PaneID
	) throws {
		guard Set(topology.paneIDs).count == topology.paneIDs.count else {
			throw WorkspaceTemplateError.duplicatePaneIdentity
		}
		guard Set(topology.splitIDs).count == topology.splitIDs.count else {
			throw WorkspaceTemplateError.duplicateSplitIdentity
		}
		guard topology.paneIDs.contains(preferredPaneID) else {
			throw WorkspaceTemplateError.preferredPaneNotFound
		}
	}
}

private struct DynamicCodingKey: CodingKey {
	let stringValue: String
	let intValue: Int?

	init?(stringValue: String) {
		self.stringValue = stringValue
		intValue = nil
	}

	init?(intValue: Int) {
		stringValue = String(intValue)
		self.intValue = intValue
	}
}

private func rejectUnexpectedKeys(
	from decoder: Decoder,
	allowed: Set<String>
) throws {
	let container = try decoder.container(keyedBy: DynamicCodingKey.self)
	if let unexpected = container.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
		throw WorkspaceTemplateError.unexpectedField(unexpected.stringValue)
	}
}

@MainActor
public final class WorkspaceTemplateStore: ObservableObject {
	@Published public private(set) var templates: [WorkspaceTemplate] = []
	@Published public private(set) var quarantinedRecordCount = 0
	@Published public private(set) var recordIssueCount = 0

	private let persistence: WorkspaceTemplatePersistence
	private var appliedRevision: UInt64 = 0

	public init(directory: URL) {
		persistence = WorkspaceTemplatePersistence(
			directory: directory,
			permissionSetter: { path in
				try FileManager.default.setAttributes(
					[.posixPermissions: 0o600],
					ofItemAtPath: path
				)
			}
		)
	}

	init(
		directory: URL,
		permissionSetter: @escaping @Sendable (String) throws -> Void
	) {
		persistence = WorkspaceTemplatePersistence(
			directory: directory,
			permissionSetter: permissionSetter
		)
	}

	public func load() async throws {
		let result = try await persistence.load()
		guard apply(result.snapshot) else { return }
		quarantinedRecordCount = result.quarantinedRecordCount
		recordIssueCount = result.recordIssueCount
	}

	@discardableResult
	public func save(workspace: Workspace, name: String) async throws -> WorkspaceTemplate {
		let template = try WorkspaceTemplate(workspace: workspace, name: name)
		apply(try await persistence.persist(template))
		return template
	}

	public func rename(id: WorkspaceTemplateID, to name: String) async throws {
		guard let template = templates.first(where: { $0.id == id }) else {
			throw WorkspaceTemplateError.templateNotFound
		}
		let renamed = try template.renamed(to: name)
		apply(try await persistence.persist(renamed))
	}

	@discardableResult
	public func duplicate(
		id: WorkspaceTemplateID,
		name: String? = nil
	) async throws -> WorkspaceTemplate {
		guard let template = templates.first(where: { $0.id == id }) else {
			throw WorkspaceTemplateError.templateNotFound
		}
		let duplicate = try template.duplicated(name: name ?? "\(template.name) Copy")
		apply(try await persistence.persist(duplicate))
		return duplicate
	}

	public func delete(id: WorkspaceTemplateID) async throws {
		guard templates.contains(where: { $0.id == id }) else {
			throw WorkspaceTemplateError.templateNotFound
		}
		apply(try await persistence.delete(id: id))
	}

	@discardableResult
	private func apply(_ snapshot: WorkspaceTemplatePersistence.Snapshot) -> Bool {
		guard snapshot.revision >= appliedRevision else { return false }
		appliedRevision = snapshot.revision
		templates = Self.sorted(snapshot.templates)
		return true
	}

	private static func sorted(_ templates: [WorkspaceTemplate]) -> [WorkspaceTemplate] {
		templates.sorted { lhs, rhs in
			let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
			if comparison != .orderedSame { return comparison == .orderedAscending }
			return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
		}
	}
}

private struct VersionHeader: Decodable {
	let version: Int
}

private actor WorkspaceTemplatePersistence {
	struct Snapshot: Sendable {
		let revision: UInt64
		let templates: [WorkspaceTemplate]
	}

	struct LoadResult: Sendable {
		let snapshot: Snapshot
		let quarantinedRecordCount: Int
		let recordIssueCount: Int
	}

	private struct Candidate: Sendable {
		let url: URL
		let storedVersion: Int
		let template: WorkspaceTemplate
	}

	private let recordsDirectory: URL
	private let quarantineDirectory: URL
	private let fileManager = FileManager()
	private let encoder: JSONEncoder
	private let permissionSetter: @Sendable (String) throws -> Void
	private var sourceURLsByID: [WorkspaceTemplateID: Set<URL>] = [:]
	private var templatesByID: [WorkspaceTemplateID: WorkspaceTemplate] = [:]
	private var revision: UInt64 = 0

	init(
		directory: URL,
		permissionSetter: @escaping @Sendable (String) throws -> Void
	) {
		recordsDirectory = directory.appendingPathComponent(
			"WorkspaceTemplates",
			isDirectory: true
		)
		quarantineDirectory = recordsDirectory.appendingPathComponent(
			"Quarantine",
			isDirectory: true
		)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		self.encoder = encoder
		self.permissionSetter = permissionSetter
	}

	func load() throws -> LoadResult {
		try ensureDirectories()
		let urls: [URL]
		do {
			urls = try fileManager.contentsOfDirectory(
				at: recordsDirectory,
				includingPropertiesForKeys: [.isRegularFileKey],
				options: [.skipsHiddenFiles]
			).filter { $0.pathExtension.lowercased() == "json" }
		} catch {
			throw WorkspaceTemplateError.persistence(error.localizedDescription)
		}

		var candidates: [Candidate] = []
		var quarantinedCount = 0
		var issueCount = 0
		for url in urls {
			let data: Data
			do {
				data = try Data(contentsOf: url)
			} catch {
				issueCount += 1
				continue
			}
			do {
				candidates.append(Candidate(
					url: url,
					storedVersion: try JSONDecoder().decode(
						VersionHeader.self,
						from: data
					).version,
					template: try JSONDecoder().decode(WorkspaceTemplate.self, from: data)
				))
			} catch {
				if isolate(url) {
					quarantinedCount += 1
				} else {
					issueCount += 1
				}
			}
		}

		var loaded: [WorkspaceTemplate] = []
		var nextSources: [WorkspaceTemplateID: Set<URL>] = [:]
		let groups = Dictionary(grouping: candidates, by: { $0.template.id })
		for id in groups.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
			guard let group = groups[id] else { continue }
			let canonicalURL = recordURL(for: id)
			let chosen = group.first(where: {
				$0.url.standardizedFileURL == canonicalURL.standardizedFileURL
			}) ?? group.min(by: { $0.url.lastPathComponent < $1.url.lastPathComponent })
			guard let chosen else { continue }

			var sources = Set(group.map(\.url))
			for duplicate in group where duplicate.url != chosen.url {
				if isolate(duplicate.url) {
					quarantinedCount += 1
					sources.remove(duplicate.url)
				} else {
					issueCount += 1
				}
			}

			if chosen.storedVersion < WorkspaceTemplate.currentVersion
				|| chosen.url.standardizedFileURL != canonicalURL.standardizedFileURL {
				do {
					try writeCanonical(chosen.template)
					sources.insert(canonicalURL)
					if chosen.url.standardizedFileURL != canonicalURL.standardizedFileURL {
						do {
							try fileManager.removeItem(at: chosen.url)
							sources.remove(chosen.url)
						} catch {
							issueCount += 1
						}
					}
				} catch {
					issueCount += 1
				}
			}

			nextSources[id] = sources
			loaded.append(chosen.template)
		}
		sourceURLsByID = nextSources
		templatesByID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
		revision &+= 1
		return LoadResult(
			snapshot: snapshot(),
			quarantinedRecordCount: quarantinedCount,
			recordIssueCount: issueCount
		)
	}

	func persist(_ template: WorkspaceTemplate) throws -> Snapshot {
		try writeCanonical(template)
		let canonicalURL = recordURL(for: template.id)
		var remaining: Set<URL> = [canonicalURL]
		for source in sourceURLsByID[template.id, default: []]
			where source.standardizedFileURL != canonicalURL.standardizedFileURL {
			do {
				if fileManager.fileExists(atPath: source.path) {
					try fileManager.removeItem(at: source)
				}
			} catch {
				remaining.insert(source)
			}
		}
		sourceURLsByID[template.id] = remaining
		templatesByID[template.id] = template
		revision &+= 1
		return snapshot()
	}

	func delete(id: WorkspaceTemplateID) throws -> Snapshot {
		let targets = sourceURLsByID[id, default: []].union([recordURL(for: id)])
		var failures: [String] = []
		for target in targets where fileManager.fileExists(atPath: target.path) {
			do {
				try fileManager.removeItem(at: target)
			} catch {
				failures.append(error.localizedDescription)
			}
		}
		guard failures.isEmpty else {
			throw WorkspaceTemplateError.persistence(failures.joined(separator: "; "))
		}
		sourceURLsByID.removeValue(forKey: id)
		templatesByID.removeValue(forKey: id)
		revision &+= 1
		return snapshot()
	}

	private func snapshot() -> Snapshot {
		Snapshot(revision: revision, templates: Array(templatesByID.values))
	}

	private func writeCanonical(_ template: WorkspaceTemplate) throws {
		let temporaryURL = recordsDirectory.appendingPathComponent(
			".\(template.id.rawValue.uuidString)-\(UUID().uuidString).tmp"
		)
		defer { try? fileManager.removeItem(at: temporaryURL) }
		do {
			try ensureDirectories()
			let url = recordURL(for: template.id)
			try encoder.encode(template).write(to: temporaryURL, options: .atomic)
			try permissionSetter(temporaryURL.path)
			if fileManager.fileExists(atPath: url.path) {
				_ = try fileManager.replaceItemAt(
					url,
					withItemAt: temporaryURL,
					backupItemName: nil,
					options: []
				)
			} else {
				try fileManager.moveItem(at: temporaryURL, to: url)
			}
		} catch let error as WorkspaceTemplateError {
			throw error
		} catch {
			throw WorkspaceTemplateError.persistence(error.localizedDescription)
		}
	}

	private func ensureDirectories() throws {
		do {
			try fileManager.createDirectory(
				at: quarantineDirectory,
				withIntermediateDirectories: true
			)
		} catch {
			throw WorkspaceTemplateError.persistence(error.localizedDescription)
		}
	}

	private func isolate(_ url: URL) -> Bool {
		let destination = quarantineDirectory.appendingPathComponent(
			"\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).json"
		)
		do {
			try fileManager.moveItem(at: url, to: destination)
			return true
		} catch {
			return false
		}
	}

	private func recordURL(for id: WorkspaceTemplateID) -> URL {
		recordsDirectory.appendingPathComponent("\(id.rawValue.uuidString).json")
	}
}
