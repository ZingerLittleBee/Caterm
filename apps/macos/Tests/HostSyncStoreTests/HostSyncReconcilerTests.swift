import XCTest
@testable import HostSyncStore
@testable import SSHCommandBuilder
@testable import ServerSyncClient

final class HostSyncReconcilerTests: XCTestCase {

    // MARK: - Helpers

    func makeLocalHost(name: String, serverId: String? = nil,
                      updatedAt: Date = Date(timeIntervalSince1970: 1000)) -> SSHHost {
        var h = SSHHost(name: name, hostname: "h", port: 22, username: "u",
                        credential: .agent, createdAt: updatedAt, updatedAt: updatedAt)
        h.serverId = serverId
        return h
    }

    func makeRemoteHost(id: String, name: String,
                       updatedAt: Date = Date(timeIntervalSince1970: 1000)) -> RemoteHost {
        RemoteHost(id: id, name: name, hostname: "h", port: 22, username: "u",
                   authType: "key", createdAt: updatedAt, updatedAt: updatedAt)
    }

    // MARK: - Empty cases

    func testEmptyEmpty() {
        let ops = HostSyncReconciler.reconcile(local: [], remote: [])
        XCTAssertTrue(ops.isEmpty)
    }

    // MARK: - Local-only

    func testLocalOnlyUploadsNewHost() {
        let h = makeLocalHost(name: "alpha")
        let ops = HostSyncReconciler.reconcile(local: [h], remote: [])
        XCTAssertEqual(ops, [.createRemote(localHostId: h.id)])
    }

    // MARK: - Remote-only

    func testRemoteOnlyDownloadsAsNewLocal() {
        let r = makeRemoteHost(id: "srv-1", name: "alpha")
        let ops = HostSyncReconciler.reconcile(local: [], remote: [r])
        XCTAssertEqual(ops, [.createLocal(remote: r)])
    }

    // MARK: - Match by serverId, in-sync

    func testMatchedSameUpdatedAtNoOps() {
        let t = Date(timeIntervalSince1970: 1000)
        var h = makeLocalHost(name: "alpha", serverId: "srv-1", updatedAt: t)
        h.serverId = "srv-1"
        let r = makeRemoteHost(id: "srv-1", name: "alpha", updatedAt: t)
        XCTAssertTrue(HostSyncReconciler.reconcile(local: [h], remote: [r]).isEmpty)
    }

    // MARK: - Conflict resolution: last-write-wins

    func testRemoteNewerOverwritesLocalMetadata() {
        let oldT = Date(timeIntervalSince1970: 1000)
        let newT = Date(timeIntervalSince1970: 2000)
        let h = makeLocalHost(name: "alpha", serverId: "srv-1", updatedAt: oldT)
        let r = makeRemoteHost(id: "srv-1", name: "alpha-renamed", updatedAt: newT)
        let ops = HostSyncReconciler.reconcile(local: [h], remote: [r])
        XCTAssertEqual(ops, [.updateLocal(localHostId: h.id, remote: r)])
    }

    func testLocalNewerOverwritesRemoteMetadata() {
        let oldT = Date(timeIntervalSince1970: 1000)
        let newT = Date(timeIntervalSince1970: 2000)
        let h = makeLocalHost(name: "alpha-edited", serverId: "srv-1", updatedAt: newT)
        let r = makeRemoteHost(id: "srv-1", name: "alpha", updatedAt: oldT)
        let ops = HostSyncReconciler.reconcile(local: [h], remote: [r])
        XCTAssertEqual(ops, [.updateRemote(localHostId: h.id, serverId: "srv-1")])
    }

    // MARK: - Synced-then-removed

    func testSyncedHostMissingRemoteDeletesLocally() {
        // Host has serverId (was synced before) but server no longer has it.
        // Per spec §7.1.3: "Server 端没有但本地有（其它设备删了）→ 本地也删除"
        let h = makeLocalHost(name: "alpha", serverId: "srv-1")
        let ops = HostSyncReconciler.reconcile(local: [h], remote: [])
        XCTAssertEqual(ops, [.deleteLocal(localHostId: h.id)])
    }

    func testUnsyncedHostNotInRemoteUploads() {
        // Host has no serverId — a brand-new local host. Server doesn't know
        // about it; we upload.
        let h = makeLocalHost(name: "alpha", serverId: nil)
        let ops = HostSyncReconciler.reconcile(local: [h], remote: [])
        XCTAssertEqual(ops, [.createRemote(localHostId: h.id)])
    }

    // MARK: - Mixed cases

    func testMixedLocalUnsyncedPlusRemoteOnly() {
        let local = makeLocalHost(name: "alpha", serverId: nil)
        let remote = makeRemoteHost(id: "srv-2", name: "beta")
        let ops = HostSyncReconciler.reconcile(local: [local], remote: [remote])
        // Both ops should be emitted; order is implementation-defined.
        XCTAssertEqual(ops.count, 2)
        XCTAssertTrue(ops.contains(.createRemote(localHostId: local.id)))
        XCTAssertTrue(ops.contains(.createLocal(remote: remote)))
    }

    func testMixedConflictPlusFreshRemote() {
        let oldT = Date(timeIntervalSince1970: 1000)
        let newT = Date(timeIntervalSince1970: 2000)
        let conflict = makeLocalHost(name: "alpha-edited", serverId: "srv-1", updatedAt: newT)
        let fresh = makeRemoteHost(id: "srv-2", name: "beta")
        let stale = makeRemoteHost(id: "srv-1", name: "alpha", updatedAt: oldT)
        let ops = HostSyncReconciler.reconcile(local: [conflict],
                                                remote: [stale, fresh])
        XCTAssertEqual(ops.count, 2)
        XCTAssertTrue(ops.contains(.updateRemote(localHostId: conflict.id, serverId: "srv-1")))
        XCTAssertTrue(ops.contains(.createLocal(remote: fresh)))
    }
}
