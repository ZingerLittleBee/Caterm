import CloudKit
import Foundation
import SnippetSyncClient
import os

// MARK: - SnippetCheckpointImpl

extension CloudKitSyncClient {
	/// Concrete checkpoint payload for snippet fetches.
	///
	/// Zone-key semantics in `prevZones` / `newZones` mirror those of
	/// the host `Checkpoint` type: absent key ⇒ skip; non-nil Data ⇒ rotate;
	/// nil Data ⇒ delete stored token.
	internal struct SnippetCheckpointImpl: SnippetSyncCheckpoint {
		let id: UUID
		let epoch: UInt64
		let prevZones: [String: Data?]
		let newZones: [String: Data?]
	}
}

// MARK: - Fetch + Checkpoint

extension CloudKitSyncClient {
	private static let snippetFetchLog = Logger(
		subsystem: "com.caterm.app",
		category: "cloudkit-snippet-fetch"
	)

	public func fetchSnippetChanges() async throws -> SnippetChangeBatch {
		try await drainSnippetZone(mode: .incremental)
	}

	public func fetchSnippetSnapshotAndCheckpoint() async throws -> SnippetChangeBatch {
		try await drainSnippetZone(mode: .forceFull)
	}

	public func commitSnippetCheckpoint(_ checkpoint: any SnippetSyncCheckpoint) async throws {
		guard let cp = checkpoint as? SnippetCheckpointImpl else {
			Self.snippetFetchLog.info("commitSnippetCheckpoint: foreign type, ignoring")
			return
		}
		var zoneCASes: [String: TokenCAS] = [:]
		for (zoneKey, newOpt) in cp.newZones {
			let prevOpt = cp.prevZones[zoneKey] ?? nil
			zoneCASes[zoneKey] = TokenCAS(prev: prevOpt, new: newOpt)
		}
		let outcome = await snippetTokenStore.commitTokens(
			expectedEpoch: cp.epoch,
			db: TokenCAS(prev: nil, new: nil),
			zones: zoneCASes
		)
		switch outcome {
		case .applied:
			Self.snippetFetchLog.debug("snippet checkpoint applied epoch=\(cp.epoch)")
		case .staleEpoch:
			Self.snippetFetchLog.info("snippet checkpoint stale epoch=\(cp.epoch); skipping")
		case .partialCAS(let zones, let db):
			Self.snippetFetchLog.info("snippet checkpoint partial CAS skippedZones=\(zones) skippedDb=\(db)")
		}
	}

	// MARK: - Drain

	private func drainSnippetZone(mode: SnippetSyncMode) async throws -> SnippetChangeBatch {
		let epoch = await snippetTokenStore.currentEpoch()
		let persistedZoneToken = await snippetTokenStore.loadZoneToken(snippetZoneID)
		let zoneKey = InMemoryServerChangeTokenStore.key(for: snippetZoneID)
		let prevZones: [String: Data?] = [zoneKey: persistedZoneToken?.archivedData]

		var changedSnippets: [Snippet] = []
		var deletedSnippetIDs: [UUID] = []
		var newZoneTokenData: Data?
		var tokenExpired = false

		let useToken: CKServerChangeToken? = (mode == .forceFull)
			? nil
			: (try? persistedZoneToken?.unarchive())

		do {
			var rollingToken: CKServerChangeToken? = useToken
			zoneLoop: while true {
				let result = try await database.fetchZoneChanges(
					zoneID: snippetZoneID,
					previousServerChangeToken: rollingToken
				)
				for record in result.changedRecords
				where record.recordType == CKRecordSnippetMapping.recordType {
					if let snippet = try? CKRecordSnippetMapping.decode(record) {
						changedSnippets.append(snippet)
					}
				}
				for (recordID, recordType) in result.deletedRecords
				where recordType == CKRecordSnippetMapping.recordType {
					if let uuid = UUID(uuidString: recordID.recordName) {
						deletedSnippetIDs.append(uuid)
					}
				}
				rollingToken = result.newToken
				if !result.moreComing { break zoneLoop }
			}
			if let finalToken = rollingToken,
			   let archived = try? StoredServerChangeToken.archive(finalToken) {
				newZoneTokenData = archived.archivedData
			}
		} catch let ck as CKError where ck.code == .changeTokenExpired {
			tokenExpired = true
		}

		let cp = SnippetCheckpointImpl(
			id: UUID(),
			epoch: epoch,
			prevZones: prevZones,
			newZones: [zoneKey: newZoneTokenData]
		)

		return SnippetChangeBatch(
			changedSnippets: changedSnippets,
			deletedSnippetIDs: deletedSnippetIDs,
			checkpoint: cp,
			tokenExpired: tokenExpired,
			mode: mode
		)
	}
}
