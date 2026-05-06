import Foundation

public struct Snippet: Identifiable, Codable, Equatable, Hashable, Sendable {
	public let id: UUID
	public var name: String
	public var content: String
	public var placeholders: [String]?
	public var createdAt: Date
	public var updatedAt: Date

	// Sync metadata. Mirrors SSHHost conventions.
	public var serverId: String?
	public var revision: Int
	public var metadataUpdatedAt: Date?

	public init(
		id: UUID,
		name: String,
		content: String,
		placeholders: [String]? = nil,
		createdAt: Date,
		updatedAt: Date,
		serverId: String? = nil,
		revision: Int = 0,
		metadataUpdatedAt: Date? = nil
	) {
		self.id = id
		self.name = name
		self.content = content
		self.placeholders = placeholders
		self.createdAt = createdAt
		self.updatedAt = updatedAt
		self.serverId = serverId
		self.revision = revision
		self.metadataUpdatedAt = metadataUpdatedAt
	}
}
