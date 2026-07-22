import Foundation

/// User-defined organization metadata for a saved host.
///
/// A group path models nested groups without requiring a second persisted
/// entity graph. Tags are case-insensitively unique while preserving the
/// spelling and order chosen by the user.
public struct HostOrganization: Codable, Hashable, Sendable {
	public static let empty = HostOrganization()

	public let groupPath: [String]
	public let tags: [String]

	public init(groupPath: [String] = [], tags: [String] = []) {
		self.groupPath = Self.normalizedComponents(groupPath)
		self.tags = Self.normalizedTags(tags)
	}

	private enum CodingKeys: String, CodingKey {
		case groupPath, tags
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.init(
			groupPath: try container.decodeIfPresent(
				[String].self, forKey: .groupPath
			) ?? [],
			tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? []
		)
	}

	public var groupDisplayName: String? {
		guard !groupPath.isEmpty else { return nil }
		return groupPath.joined(separator: " / ")
	}

	private static func normalizedComponents(_ values: [String]) -> [String] {
		values.compactMap { value in
			let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? nil : trimmed
		}
	}

	private static func normalizedTags(_ values: [String]) -> [String] {
		var seen: Set<String> = []
		return normalizedComponents(values).filter { value in
			seen.insert(value.folding(
				options: [.caseInsensitive, .diacriticInsensitive],
				locale: nil
			)).inserted
		}
	}
}
