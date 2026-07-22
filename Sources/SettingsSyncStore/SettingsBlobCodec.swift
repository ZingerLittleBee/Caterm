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
	public var unknownFields: [String: SettingsOpaqueValue]

	public init(from local: CatermSettings) {
		self.version = local.version
		self.revision = local.revision
		self.global = local.global
		self.hostOverrides = local.hostOverrides
		self.seedVersion = local.seedVersion
		self.seededByDefault = local.seededByDefault
		self.firstUserEditedAt = local.firstUserEditedAt
		self.canonicalSeedHash = local.canonicalSeedHash
		self.unknownFields = local.unknownFields
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
			canonicalSeedHash: canonicalSeedHash,
			unknownFields: unknownFields
		)
	}

	private static let knownKeys: Set<String> = [
		"version", "revision", "global", "hostOverrides", "seedVersion",
		"seededByDefault", "firstUserEditedAt", "canonicalSeedHash",
	]

	private struct CodingKey: Swift.CodingKey {
		let stringValue: String
		let intValue: Int?

		init(_ value: String) {
			stringValue = value
			intValue = nil
		}

		init?(stringValue: String) { self.init(stringValue) }
		init?(intValue: Int) {
			stringValue = String(intValue)
			self.intValue = intValue
		}
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKey.self)
		func key(_ value: String) -> CodingKey { CodingKey(value) }
		version = try container.decode(Int.self, forKey: key("version"))
		revision = try container.decode(String.self, forKey: key("revision"))
		global = try container.decode(PartialSettings.self, forKey: key("global"))
		hostOverrides = try container.decode(
			[HostId: PartialSettings].self,
			forKey: key("hostOverrides")
		)
		seedVersion = try container.decode(Int.self, forKey: key("seedVersion"))
		seededByDefault = try container.decode(Bool.self, forKey: key("seededByDefault"))
		firstUserEditedAt = try container.decodeIfPresent(
			Date.self,
			forKey: key("firstUserEditedAt")
		)
		canonicalSeedHash = try container.decode(
			String.self,
			forKey: key("canonicalSeedHash")
		)
		unknownFields = try Dictionary(uniqueKeysWithValues: container.allKeys
			.filter { !Self.knownKeys.contains($0.stringValue) }
			.map { codingKey in
				(codingKey.stringValue, try container.decode(
					SettingsOpaqueValue.self,
					forKey: codingKey
				))
			})
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKey.self)
		func key(_ value: String) -> CodingKey { CodingKey(value) }
		try container.encode(version, forKey: key("version"))
		try container.encode(revision, forKey: key("revision"))
		try container.encode(global, forKey: key("global"))
		try container.encode(hostOverrides, forKey: key("hostOverrides"))
		try container.encode(seedVersion, forKey: key("seedVersion"))
		try container.encode(seededByDefault, forKey: key("seededByDefault"))
		try container.encodeIfPresent(firstUserEditedAt, forKey: key("firstUserEditedAt"))
		try container.encode(canonicalSeedHash, forKey: key("canonicalSeedHash"))
		for (field, value) in unknownFields where !Self.knownKeys.contains(field) {
			try container.encode(value, forKey: key(field))
		}
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
