import CloudKit
import Foundation
import ServerSyncClient

/// `ServerSyncClient` impl backed by a CloudKit Private Database.
///
/// Records live in a custom zone (default `Caterm`) with record type `Host`.
/// The local `SSHHost.id` UUID doubles as `CKRecord.ID.recordName`, so
/// creates are idempotent and there is no "server-allocated id round-trip"
/// race (cf. `HostSyncStore.swift:403` warning).
public final class CloudKitSyncClient: ServerSyncClient {
    internal let database: CKDatabaseProtocol
    internal let zoneID: CKRecordZone.ID
    internal let tokenStore: any ServerChangeTokenStoring
    internal let snippetTokenStore: any ServerChangeTokenStoring

    /// Concrete checkpoint payload. Internal — only this module
    /// constructs / interprets values.
    ///
    /// Zone-key semantics in `prevZones` / `newZones`:
    /// - **Key absent from `newZones`**: zone returned no token from this drain;
    ///   commit must SKIP that zone (do not write, do not delete).
    /// - **Key present with non-nil `Data`**: rotate the zone's stored token
    ///   forward to the new value via CAS against `prevZones[key]`.
    /// - **Key present with `nil` value**: delete the zone's stored token
    ///   (used by the Caterm-zone destruction short-circuit).
    /// `db` follows the same rule: `newDb == nil` while `prevDb` is non-nil
    /// means delete the database token; `newDb == nil` and `prevDb == nil`
    /// means no-op.
    internal struct Checkpoint: HostSyncCheckpoint {
        let id: UUID
        let epoch: UInt64
        let prevDb: Data?
        let newDb: Data?
        let prevZones: [String: Data?]
        let newZones: [String: Data?]
    }

    public convenience init(
        database: CKDatabaseProtocol,
        zoneID: CKRecordZone.ID = CKRecordZone.ID(zoneName: "Caterm")
    ) {
        self.init(
            database: database, zoneID: zoneID,
            tokenStore: UserDefaultsServerChangeTokenStore(),
            snippetTokenStore: UserDefaultsServerChangeTokenStore(
                keyPrefix: "cloudkit.changeToken.snippet"
            )
        )
    }

    internal init(database: CKDatabaseProtocol,
                  zoneID: CKRecordZone.ID,
                  tokenStore: any ServerChangeTokenStoring,
                  snippetTokenStore: any ServerChangeTokenStoring = InMemoryServerChangeTokenStore()) {
        self.database = database
        self.zoneID = zoneID
        self.tokenStore = tokenStore
        self.snippetTokenStore = snippetTokenStore
    }

    public func listHosts() async throws -> [RemoteHost] {
        let query = CKQuery(recordType: CKRecordHostMapping.recordType,
                            predicate: NSPredicate(value: true))
        do {
            let (matches, _) = try await database.records(
                matching: query, inZoneWith: zoneID,
                desiredKeys: nil, resultsLimit: CKQueryOperation.maximumResults
            )
            var hosts: [RemoteHost] = []
            for (_, result) in matches {
                if case let .success(rec) = result,
                   let result = try? CKRecordHostMapping.decode(rec) {
                    hosts.append(result.host)
                }
                // Per-record .failure(_) and decode failures are silently
                // skipped: a single bad record must not poison the whole
                // sync pass. The reconciler relies on listHosts being a snapshot of
                // "what the server has that I can interpret"; a corrupt record
                // (e.g. missing fields from a future schema version) silently
                // drops out and the pass continues.
                // TODO(post-migration): log skipped records via os.Logger so
                // schema-drift bugs are diagnosable in Console.app. Tracked
                // separately from Plan A — out of scope for the CloudKit
                // migration itself.
            }
            return hosts
        } catch let ck as CKError where ck.code == .zoneNotFound {
            // First-ever launch on a fresh iCloud account: the Caterm zone
            // has not been created yet. Treat as "no remote records" so the
            // reconciler can proceed; the next createHost call will run
            // ensureZone and lazily create the zone before saving.
            return []
        } catch {
            throw CloudKitErrorMapping.map(error)
        }
    }

    public func createHost(_ input: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput {
        do {
            try await ensureZone()
            let recordName = UUID().uuidString
            let rec = CKRecordHostMapping.makeRecord(
                recordName: recordName, zoneID: zoneID, input: input
            )
            let saved = try await database.save(rec)
            return RemoteHostCreateOutput(id: saved.recordID.recordName)
        } catch {
            throw CloudKitErrorMapping.map(error)
        }
    }

    /// Idempotent zone bootstrap. The first `save` against a fresh container
    /// fails with `CKError.zoneNotFound` if we don't ensure the zone exists.
    /// `database.save(zone:)` is itself idempotent (no-op on a zone that
    /// already exists).
    private func ensureZone() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.save(zone)
    }

    /// `ensureZone()` is intentionally NOT called here. updateHost is only
    /// reached after the host already exists somewhere in the user's
    /// container (either via `createHost` on this device, or via
    /// reconciler `.createLocal` adoption from a record another device
    /// wrote). In both cases, the zone has been auto-created on the
    /// server side already. Adding `ensureZone()` here would add a
    /// per-edit zone-save round-trip with no functional benefit.
    public func updateHost(_ input: RemoteHostUpdateInput) async throws {
        let recID = CKRecord.ID(recordName: input.id, zoneID: zoneID)
        do {
            let rec = try await database.record(for: recID)
            CKRecordHostMapping.applyMetadata(into: rec, from: input)
            _ = try await database.save(rec)
        // Two-catch pattern: pass through any ServerSyncError thrown by
        // pre-condition validation that may be added inside the do block
        // (none today — defensive against future additions). Map raw
        // CKErrors / URLErrors to ServerSyncError uniformly.
        } catch let e as ServerSyncError {
            throw e
        } catch {
            throw CloudKitErrorMapping.map(error)
        }
    }

    public func deleteHost(id: String) async throws {
        let recID = CKRecord.ID(recordName: id, zoneID: zoneID)
        do {
            _ = try await database.deleteRecord(withID: recID)
        } catch let ck as CKError where ck.code == .unknownItem {
            // Idempotent: deleting an already-gone host is a no-op. Two
            // races make this reachable: (a) reconciler-emitted deletes
            // after another device removed the same host first, (b)
            // double-fire from rapid local-delete + sync.
            return
        } catch {
            throw CloudKitErrorMapping.map(error)
        }
    }
}
