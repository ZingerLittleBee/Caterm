import Foundation

public struct HostCredentialIdentityReference: Codable, Equatable, Hashable,
	Sendable {
	public enum MigrationState: String, Codable, Equatable, Hashable,
		Sendable {
		case reversible
		case confirmed
	}

	public var identityID: UUID
	public var migrationState: MigrationState

	public init(
		identityID: UUID,
		migrationState: MigrationState = .confirmed
	) {
		self.identityID = identityID
		self.migrationState = migrationState
	}
}
