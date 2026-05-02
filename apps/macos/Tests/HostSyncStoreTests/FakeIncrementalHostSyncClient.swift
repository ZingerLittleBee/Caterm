import CredentialSyncTypes
import Foundation
@testable import ServerSyncClient

struct FakeCheckpoint: HostSyncCheckpoint, Sendable {
    let id: UUID
}

struct CommitCall: Sendable {
    let id: UUID
}

struct PushCredentialCall: Sendable {
    let serverId: String
    let blob: CredentialBlob
}

/// Test fake that gives precise control over fetch/commit ordering and outcome,
/// distinct from FakeServerSyncClient (which mirrors the legacy listHosts flow).
final class FakeIncrementalHostSyncClient: IncrementalHostSyncClient, @unchecked Sendable {
    /// Result returned by the FIRST call to either fetch* method.
    var fetchSnapshotResult: HostChangeBatch?
    /// Result returned by the SECOND call (used for tokenExpired retry tests).
    var fetchSnapshotResultRetry: HostChangeBatch?
    /// Modes recorded in the order each fetch was invoked.
    private(set) var fetchModes: [HostSyncMode] = []
    /// Each commit call captured.
    private(set) var commitCalls: [CommitCall] = []

    // MARK: - Per-method error stubs

    var listResult: [RemoteHost] = []
    var createHostError: Error?
    var updateHostError: Error?
    var deleteHostError: Error?

    // MARK: - Credential push

    private(set) var pushCredentialCalls: [PushCredentialCall] = []
    var pushCredentialError: Error?
    var pushCredentialReturn: Int64 = 1

    func pushHostCredentialBlob(serverId: String, blob: CredentialBlob) async throws -> Int64 {
        if let err = pushCredentialError { throw err }
        pushCredentialCalls.append(PushCredentialCall(serverId: serverId, blob: blob))
        return pushCredentialReturn
    }

    // MARK: - ServerSyncClient (legacy list/create/update/delete)

    func listHosts() async throws -> [RemoteHost] { listResult }

    func createHost(_ input: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput {
        if let err = createHostError { throw err }
        return RemoteHostCreateOutput(id: "srv-\(UUID().uuidString.prefix(8))")
    }

    func updateHost(_ input: RemoteHostUpdateInput) async throws {
        if let err = updateHostError { throw err }
    }

    func deleteHost(id: String) async throws {
        if let err = deleteHostError { throw err }
    }

    // MARK: - IncrementalHostSyncClient

    func preferredHostSyncMode() async -> HostSyncMode { .forceFull }

    func fetchHostChanges() async throws -> HostChangeBatch {
        fetchModes.append(.incremental)
        return takeNextBatch()
    }

    func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch {
        fetchModes.append(.forceFull)
        return takeNextBatch()
    }

    private func takeNextBatch() -> HostChangeBatch {
        let isFirst = fetchModes.count == 1
        if isFirst, let b = fetchSnapshotResult { return b }
        if !isFirst, let r = fetchSnapshotResultRetry { return r }
        return HostChangeBatch(
            changedHosts: [], deletedHostIDs: [],
            checkpoint: nil, tokenExpired: false, mode: .forceFull
        )
    }

    func commitHostCheckpoint(_ checkpoint: any HostSyncCheckpoint) async throws {
        guard let cp = checkpoint as? FakeCheckpoint else {
            throw NSError(
                domain: "FakeIncrementalHostSyncClient", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "expected FakeCheckpoint"]
            )
        }
        commitCalls.append(CommitCall(id: cp.id))
    }

    func resetHostSyncState() async {}
    func ensureHostSubscription() async throws {}
    func deleteHostSubscription() async throws {}
}
