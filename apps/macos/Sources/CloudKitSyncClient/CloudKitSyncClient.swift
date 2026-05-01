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
    private let database: CKDatabaseProtocol
    private let zoneID: CKRecordZone.ID

    public init(database: CKDatabaseProtocol,
                zoneID: CKRecordZone.ID = CKRecordZone.ID(zoneName: "Caterm")) {
        self.database = database
        self.zoneID = zoneID
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
                   let host = try? CKRecordHostMapping.decode(rec) {
                    hosts.append(host)
                }
                // Per-record .failure(_) and decode failures are silently
                // skipped: a single bad record must not poison the whole
                // sync pass. The reconciler relies on listHosts being a snapshot of
                // "what the server has that I can interpret"; a corrupt record
                // (e.g. missing fields from a future schema version) silently
                // drops out and the pass continues.
                // TODO(Task 10): log skipped records via os.Logger so schema-drift
                // bugs are diagnosable in Console.app.
            }
            return hosts
        } catch {
            throw CloudKitErrorMapping.map(error)
        }
    }

    public func createHost(_ input: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput {
        // Replaced in Task 7. Throws (rather than fatalError) so a misconfigured
        // build that lands wiring before this task does NOT hard-crash on host
        // mutations — the user sees a sync failure they can recover from.
        throw ServerSyncError.http(status: 501, body: "not implemented: Task 7")
    }

    public func updateHost(_ input: RemoteHostUpdateInput) async throws {
        throw ServerSyncError.http(status: 501, body: "not implemented: Task 8")
    }

    public func deleteHost(id: String) async throws {
        throw ServerSyncError.http(status: 501, body: "not implemented: Task 9")
    }
}
