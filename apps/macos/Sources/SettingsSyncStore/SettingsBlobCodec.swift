import Foundation
import SettingsStore

/// On-the-wire shape for KVS. Excludes `migrationsCompleted`, which is
/// per-device filesystem state and explicitly never travels.
public struct SyncableSettings: Codable, Equatable {
	public var version: Int
	public var revision: String
	public var global: PartialSettings
	public var hostOverrides: [HostId: PartialSettings]
	public var seedVersion: Int
	public var seededByDefault: Bool
	public var firstUserEditedAt: Date?
	public var canonicalSeedHash: String

	public init(from local: CatermSettings) {
		self.version = local.version
		self.revision = local.revision
		self.global = local.global
		self.hostOverrides = local.hostOverrides
		self.seedVersion = local.seedVersion
		self.seededByDefault = local.seededByDefault
		self.firstUserEditedAt = local.firstUserEditedAt
		self.canonicalSeedHash = local.canonicalSeedHash
	}

	/// Inflate to a full CatermSettings using the local migrations set.
	/// Sync never sets migrationsCompleted — that always comes from local.
	public func toLocal(localMigrationsCompleted: Set<String>) -> CatermSettings {
		CatermSettings(
			version: version,
			revision: revision,
			global: global,
			hostOverrides: hostOverrides,
			migrationsCompleted: localMigrationsCompleted,
			seedVersion: seedVersion,
			seededByDefault: seededByDefault,
			firstUserEditedAt: firstUserEditedAt,
			canonicalSeedHash: canonicalSeedHash
		)
	}
}

public enum SettingsBlobCodec {
	public static func encode(_ s: CatermSettings) throws -> Data {
		let projected = SyncableSettings(from: s)
		return try PropertyListEncoder().encode(projected)
	}

	public static func decode(_ data: Data) throws -> SyncableSettings {
		return try PropertyListDecoder().decode(SyncableSettings.self, from: data)
	}
}
