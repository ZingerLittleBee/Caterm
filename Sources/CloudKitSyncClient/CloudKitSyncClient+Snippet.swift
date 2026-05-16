import CloudKit
import Foundation
import SnippetSyncClient
import os

extension CloudKitSyncClient: IncrementalSnippetSyncClient {
	private static let snippetLog = Logger(subsystem: "com.caterm.app", category: "cloudkit-snippet-sync")

	/// Custom zone for snippets — distinct from the Caterm host zone.
	internal var snippetZoneID: CKRecordZone.ID {
		CKRecordZone.ID(
			zoneName: CloudKitPushNames.snippetZoneName,
			ownerName: CKCurrentUserDefaultName
		)
	}

	public func preferredSnippetSyncMode() async -> SnippetSyncMode {
		let stored = await snippetTokenStore.loadDatabaseToken()
		return stored == nil ? .forceFull : .incremental
	}

	public func pushSnippet(_ s: Snippet) async throws -> Snippet {
		try await ensureSnippetZone()
		let rec = CKRecordSnippetMapping.encode(s, zoneID: snippetZoneID)
		let saved = try await database.save(rec)
		var copy = s
		copy.serverId = saved.recordID.recordName
		copy.metadataUpdatedAt = saved.modificationDate
		return copy
	}

	public func deleteSnippet(id: UUID) async throws {
		let recID = CKRecord.ID(recordName: id.uuidString, zoneID: snippetZoneID)
		do {
			_ = try await database.deleteRecord(withID: recID)
		} catch let ck as CKError where ck.code == .unknownItem {
			// Already gone — treat as success.
			return
		}
	}

	public func ensureSnippetSubscription() async throws {
		let sub = CKDatabaseSubscription(subscriptionID: CloudKitPushNames.snippetSubscriptionID)
		sub.recordType = CKRecordSnippetMapping.recordType
		let info = CKSubscription.NotificationInfo()
		info.shouldSendContentAvailable = true
		sub.notificationInfo = info
		do {
			_ = try await database.saveSubscription(sub)
		} catch let ck as CKError where ck.code == .serverRejectedRequest {
			return
		}
	}

	public func deleteSnippetSubscription() async throws {
		do {
			_ = try await database.deleteSubscription(
				withID: CloudKitPushNames.snippetSubscriptionID
			)
		} catch let ck as CKError where ck.code == .unknownItem {
			return
		}
	}

	public func resetSnippetSyncState() async {
		await snippetTokenStore.clearAll()
	}

	public func hasAnySnippetSyncTokens() async -> Bool {
		await snippetTokenStore.loadDatabaseToken() != nil
	}

	// MARK: - Internals

	private func ensureSnippetZone() async throws {
		let zone = CKRecordZone(zoneID: snippetZoneID)
		do {
			_ = try await database.save(zone)
		} catch let ck as CKError where ck.code == .serverRejectedRequest {
			return
		}
	}
}
