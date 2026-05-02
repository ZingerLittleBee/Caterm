import CloudKit
import Foundation

internal enum ServerChangeTokenError: Error, Sendable {
	case unarchiveReturnedNil
}

internal struct StoredServerChangeToken: Equatable, Sendable {
	let archivedData: Data

	init(archivedData: Data) { self.archivedData = archivedData }

	static func archive(_ token: CKServerChangeToken) throws -> StoredServerChangeToken {
		let data = try NSKeyedArchiver.archivedData(
			withRootObject: token, requiringSecureCoding: true
		)
		return StoredServerChangeToken(archivedData: data)
	}

	func unarchive() throws -> CKServerChangeToken {
		guard let token = try NSKeyedUnarchiver.unarchivedObject(
			ofClass: CKServerChangeToken.self, from: archivedData
		) else {
			throw ServerChangeTokenError.unarchiveReturnedNil
		}
		return token
	}
}

internal struct TokenCAS: Sendable {
	let prev: Data?
	let new: Data?
}

internal enum CommitOutcome: Sendable, Equatable {
	case applied
	case staleEpoch
	case partialCAS(skippedZoneKeys: [String], skippedDb: Bool)
}

internal protocol ServerChangeTokenStoring: Sendable {
	func currentEpoch() async -> UInt64
	func bumpEpoch() async
	func loadDatabaseToken() async -> StoredServerChangeToken?
	func loadZoneToken(_ zoneID: CKRecordZone.ID) async -> StoredServerChangeToken?
	func commitTokens(expectedEpoch: UInt64,
	                  db: TokenCAS,
	                  zones: [String: TokenCAS]) async -> CommitOutcome
	func clearAll() async
}

internal actor InMemoryServerChangeTokenStore: ServerChangeTokenStoring {
	private var epoch: UInt64 = 0
	private var dbToken: StoredServerChangeToken?
	private var zoneTokens: [String: StoredServerChangeToken] = [:]

	init() {}

	func currentEpoch() async -> UInt64 { epoch }
	func bumpEpoch() async { epoch &+= 1 }

	func loadDatabaseToken() async -> StoredServerChangeToken? { dbToken }
	func loadZoneToken(_ zoneID: CKRecordZone.ID) async -> StoredServerChangeToken? {
		zoneTokens[Self.key(for: zoneID)]
	}

	func commitTokens(expectedEpoch: UInt64,
	                  db: TokenCAS,
	                  zones: [String: TokenCAS]) async -> CommitOutcome {
		guard expectedEpoch == epoch else { return .staleEpoch }
		var skippedZones: [String] = []
		var skippedDb = false

		for (zoneKey, cas) in zones {
			let persistedArchive = zoneTokens[zoneKey]?.archivedData
			if persistedArchive == cas.prev {
				if let new = cas.new {
					zoneTokens[zoneKey] = StoredServerChangeToken(archivedData: new)
				} else {
					zoneTokens.removeValue(forKey: zoneKey)
				}
			} else {
				skippedZones.append(zoneKey)
			}
		}

		let persistedDbArchive = dbToken?.archivedData
		if persistedDbArchive == db.prev {
			if let new = db.new {
				dbToken = StoredServerChangeToken(archivedData: new)
			} else {
				dbToken = nil
			}
		} else {
			skippedDb = true
		}

		if skippedZones.isEmpty && !skippedDb { return .applied }
		return .partialCAS(skippedZoneKeys: skippedZones, skippedDb: skippedDb)
	}

	func clearAll() async {
		epoch &+= 1
		dbToken = nil
		zoneTokens.removeAll()
	}

	static func key(for zoneID: CKRecordZone.ID) -> String {
		"\(zoneID.zoneName).\(zoneID.ownerName)"
	}
}

internal actor UserDefaultsServerChangeTokenStore: ServerChangeTokenStoring {
	// MIGRATION NOTE: These keys are persisted to UserDefaults across app
	// launches and app updates. They MUST NOT be renamed without a migration
	// that reads the old key, writes the new key, and deletes the old one.
	// A silent rename would orphan existing tokens and force a full re-fetch.
	private static let dbKey = "cloudkit.changeToken.database"
	private static let epochKey = "cloudkit.changeToken.epoch"
	private static let zonePrefix = "cloudkit.changeToken.zone."

	private let defaults: UserDefaults

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
	}

	func currentEpoch() async -> UInt64 {
		UInt64(bitPattern: Int64(defaults.integer(forKey: Self.epochKey)))
	}

	// Round-trips UInt64 through Int64 bitPattern, then through UserDefaults'
	// integer(forKey:) which returns Int. Correct only on 64-bit platforms
	// (Int == Int64). All current Apple platforms qualify; revisit if 32-bit
	// targets are added.
	func bumpEpoch() async {
		let current = await currentEpoch()
		defaults.set(Int64(bitPattern: current &+ 1), forKey: Self.epochKey)
	}

	func loadDatabaseToken() async -> StoredServerChangeToken? {
		defaults.data(forKey: Self.dbKey).map { StoredServerChangeToken(archivedData: $0) }
	}

	func loadZoneToken(_ zoneID: CKRecordZone.ID) async -> StoredServerChangeToken? {
		defaults.data(forKey: Self.zoneKey(for: zoneID))
			.map { StoredServerChangeToken(archivedData: $0) }
	}

	func commitTokens(expectedEpoch: UInt64,
	                  db: TokenCAS,
	                  zones: [String: TokenCAS]) async -> CommitOutcome {
		guard await currentEpoch() == expectedEpoch else { return .staleEpoch }

		var skippedZones: [String] = []
		var skippedDb = false

		for (zoneKey, cas) in zones {
			let storageKey = Self.zonePrefix + zoneKey
			let persisted = defaults.data(forKey: storageKey)
			if persisted == cas.prev {
				if let new = cas.new {
					defaults.set(new, forKey: storageKey)
				} else {
					defaults.removeObject(forKey: storageKey)
				}
			} else {
				skippedZones.append(zoneKey)
			}
		}

		let persistedDb = defaults.data(forKey: Self.dbKey)
		if persistedDb == db.prev {
			if let new = db.new {
				defaults.set(new, forKey: Self.dbKey)
			} else {
				defaults.removeObject(forKey: Self.dbKey)
			}
		} else {
			skippedDb = true
		}

		if skippedZones.isEmpty && !skippedDb { return .applied }
		return .partialCAS(skippedZoneKeys: skippedZones, skippedDb: skippedDb)
	}

	func clearAll() async {
		await bumpEpoch()
		defaults.removeObject(forKey: Self.dbKey)
		for key in defaults.dictionaryRepresentation().keys
		where key.hasPrefix(Self.zonePrefix) {
			defaults.removeObject(forKey: key)
		}
	}

	private static func zoneKey(for zoneID: CKRecordZone.ID) -> String {
		zonePrefix + InMemoryServerChangeTokenStore.key(for: zoneID)
	}
}
