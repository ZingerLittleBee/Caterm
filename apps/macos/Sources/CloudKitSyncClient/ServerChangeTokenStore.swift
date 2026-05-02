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
