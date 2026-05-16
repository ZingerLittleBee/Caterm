import CloudKit
import CredentialSyncTypes
import Foundation
import ServerSyncClient
import os

extension CloudKitSyncClient: IncrementalHostSyncClient {
    private static let log = Logger(subsystem: "com.caterm.app", category: "cloudkit-sync")
    private static let hostRecordType = "Host"

    public func preferredHostSyncMode() async -> HostSyncMode {
        let stored = await tokenStore.loadDatabaseToken()
        return stored == nil ? .forceFull : .incremental
    }

    public func fetchHostChanges() async throws -> HostChangeBatch {
        try await drain(mode: .incremental)
    }

    public func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch {
        try await drain(mode: .forceFull)
    }

    public func commitHostCheckpoint(_ checkpoint: any HostSyncCheckpoint) async throws {
        guard let cp = checkpoint as? Checkpoint else {
            Self.log.info("commitHostCheckpoint: foreign type, ignoring")
            return
        }
        let dbCAS = TokenCAS(prev: cp.prevDb, new: cp.newDb)
        var zoneCASes: [String: TokenCAS] = [:]
        for (zoneKey, newOpt) in cp.newZones {
            let prevOpt = cp.prevZones[zoneKey] ?? nil
            zoneCASes[zoneKey] = TokenCAS(prev: prevOpt, new: newOpt)
        }
        let outcome = await tokenStore.commitTokens(
            expectedEpoch: cp.epoch, db: dbCAS, zones: zoneCASes
        )
        switch outcome {
        case .applied:
            Self.log.debug("checkpoint applied epoch=\(cp.epoch)")
        case .staleEpoch:
            Self.log.info("checkpoint stale by epoch \(cp.epoch); skipping")
        case .partialCAS(let zones, let db):
            Self.log.info("checkpoint partial CAS skippedZones=\(zones) skippedDb=\(db)")
        }
    }

    public func resetHostSyncState() async {
        await tokenStore.clearAll()
    }

    public func ensureHostSubscription() async throws {
        let sub = CKDatabaseSubscription(subscriptionID: CloudKitPushNames.hostSubscriptionID)
        sub.recordType = Self.hostRecordType
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        do {
            _ = try await database.saveSubscription(sub)
        } catch let ck as CKError where ck.code == .serverRejectedRequest {
            // Subscription already exists. Apple returns this when a
            // subscription with the same ID is present.
            return
        }
    }

    public func deleteHostSubscription() async throws {
        do {
            _ = try await database.deleteSubscription(
                withID: CloudKitPushNames.hostSubscriptionID
            )
        } catch let ck as CKError where ck.code == .unknownItem {
            return
        }
    }

    /// Plan C — partial credential push. Honors the §Seed-before-credential-save
    /// invariant: if the existing record has no `metadataUpdatedAt`, seed it
    /// from `modificationDate`/`creationDate` (falling back to `.distantPast`)
    /// BEFORE applying the credential blob, in the same client-side mutation,
    /// then save the record exactly once. Returns `blob.revision`.
    public func pushHostCredentialBlob(
        serverId: String,
        blob: CredentialBlob
    ) async throws -> Int64 {
        let recordID = CKRecord.ID(recordName: serverId, zoneID: zoneID)
        let existing = try await database.record(for: recordID)
        if existing[CKRecordHostMapping.Field.metadataUpdatedAt] == nil {
            let seed = existing.modificationDate ?? existing.creationDate ?? Date.distantPast
            existing[CKRecordHostMapping.Field.metadataUpdatedAt] = seed as CKRecordValue
        }
        CKRecordHostMapping.applyCredentialBlob(into: existing, blob: blob)
        _ = try await database.save(existing)
        return blob.revision
    }

    // MARK: - Drain loop

    private func drain(mode: HostSyncMode) async throws -> HostChangeBatch {
        let fetchEpoch = await tokenStore.currentEpoch()
        let persistedDb = await tokenStore.loadDatabaseToken()
        let casPreviousDbArchive = persistedDb?.archivedData
        var operationPreviousDbToken: CKServerChangeToken? = nil
        if mode == .incremental, let stored = persistedDb {
            operationPreviousDbToken = (try? stored.unarchive())
            if operationPreviousDbToken == nil {
                Self.log.error("db token unarchive failed; falling back to forceFull")
            }
        }

        var changedHosts: [RemoteHost] = []
        var credentialBlobs: [String: CredentialBlob] = [:]
        var deletedHostIDs: [String] = []
        var deletedZoneIDs: Set<CKRecordZone.ID> = []
        var purgedZoneIDs: Set<CKRecordZone.ID> = []
        var encryptedResetZoneIDs: Set<CKRecordZone.ID> = []
        var casPreviousZoneArchives: [String: Data?] = [:]
        var pendingZoneTokens: [String: Data] = [:]
        var rollingDbToken: CKServerChangeToken? = operationPreviousDbToken

        databaseLoop: while true {
            let dbResult = try await database.fetchDatabaseChanges(
                previousServerChangeToken: rollingDbToken
            )
            deletedZoneIDs.formUnion(dbResult.deletedZoneIDs)
            purgedZoneIDs.formUnion(dbResult.purgedZoneIDs)
            encryptedResetZoneIDs.formUnion(dbResult.encryptedDataResetZoneIDs)

            for zoneID in dbResult.changedZoneIDs {
                let zoneKey = InMemoryServerChangeTokenStore.key(for: zoneID)
                if casPreviousZoneArchives[zoneKey] == nil {
                    let persistedZone = await tokenStore.loadZoneToken(zoneID)
                    casPreviousZoneArchives[zoneKey] = persistedZone?.archivedData
                    var operationPrev: CKServerChangeToken? = nil
                    if mode == .incremental, let stored = persistedZone {
                        operationPrev = (try? stored.unarchive())
                        if operationPrev == nil {
                            Self.log.error("zone token unarchive failed for \(zoneKey); using nil")
                        }
                    }
                    var rollingZoneToken = operationPrev

                    zoneLoop: while true {
                        let zResult = try await database.fetchZoneChanges(
                            zoneID: zoneID,
                            previousServerChangeToken: rollingZoneToken
                        )
                        for record in zResult.changedRecords
                        where record.recordType == Self.hostRecordType {
                            if let result = try? CKRecordHostMapping.decode(record) {
                                changedHosts.append(result.host)
                                if let blob = result.blob {
                                    credentialBlobs[result.host.id] = blob
                                }
                            }
                        }
                        for (recordID, recordType) in zResult.deletedRecords
                        where recordType == Self.hostRecordType {
                            deletedHostIDs.append(recordID.recordName)
                        }
                        rollingZoneToken = zResult.newToken
                        if !zResult.moreComing { break zoneLoop }
                    }

                    if let final = rollingZoneToken,
                       let archived = try? StoredServerChangeToken.archive(final) {
                        pendingZoneTokens[zoneKey] = archived.archivedData
                    }
                }
            }

            rollingDbToken = dbResult.newToken
            if !dbResult.moreComing { break databaseLoop }
        }

        // Caterm-zone destruction short-circuit.
        let catermZone = zoneID
        if deletedZoneIDs.contains(catermZone)
            || purgedZoneIDs.contains(catermZone)
            || encryptedResetZoneIDs.contains(catermZone) {
            // Wipe Caterm-zone token; commit through tokenStore so atomicity holds.
            let zoneKey = InMemoryServerChangeTokenStore.key(for: catermZone)
            _ = await tokenStore.commitTokens(
                expectedEpoch: fetchEpoch,
                db: TokenCAS(prev: casPreviousDbArchive, new: casPreviousDbArchive),
                zones: [zoneKey: TokenCAS(
                    prev: casPreviousZoneArchives[zoneKey] ?? nil,
                    new: nil
                )]
            )
            return HostChangeBatch(
                changedHosts: [], deletedHostIDs: [],
                checkpoint: nil, tokenExpired: true, mode: mode
            )
        }

        let newDbArchive: Data? = rollingDbToken.flatMap {
            try? StoredServerChangeToken.archive($0).archivedData
        }
        let prevZonesForCAS = casPreviousZoneArchives
        let newZonesForCAS: [String: Data?] = pendingZoneTokens.mapValues { Optional($0) }

        let checkpoint = Checkpoint(
            id: UUID(),
            epoch: fetchEpoch,
            prevDb: casPreviousDbArchive,
            newDb: newDbArchive,
            prevZones: prevZonesForCAS,
            newZones: newZonesForCAS
        )

        return HostChangeBatch(
            changedHosts: changedHosts,
            deletedHostIDs: deletedHostIDs,
            credentialBlobsByServerId: credentialBlobs,
            checkpoint: checkpoint,
            tokenExpired: false,
            mode: mode
        )
    }
}
