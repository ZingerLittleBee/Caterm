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
        let ops = HostSyncReconciler.reconcileFullSnapshot(local: [], remote: [])
        XCTAssertTrue(ops.isEmpty)
    }

    // MARK: - Local-only

    func testLocalOnlyUploadsNewHost() {
        let h = makeLocalHost(name: "alpha")
        let ops = HostSyncReconciler.reconcileFullSnapshot(local: [h], remote: [])
        XCTAssertEqual(ops, [.createRemote(localHostId: h.id)])
    }

    // MARK: - Remote-only

    func testRemoteOnlyDownloadsAsNewLocal() {
        let r = makeRemoteHost(id: "srv-1", name: "alpha")
        let ops = HostSyncReconciler.reconcileFullSnapshot(local: [], remote: [r])
        XCTAssertEqual(ops, [.createLocal(remote: r)])
    }

    // MARK: - Match by serverId, in-sync

    func testMatchedSameUpdatedAtNoOps() {
        let t = Date(timeIntervalSince1970: 1000)
        var h = makeLocalHost(name: "alpha", serverId: "srv-1", updatedAt: t)
        h.serverId = "srv-1"
        let r = makeRemoteHost(id: "srv-1", name: "alpha", updatedAt: t)
        XCTAssertTrue(HostSyncReconciler.reconcileFullSnapshot(local: [h], remote: [r]).isEmpty)
    }

    // MARK: - Icon sync (machine A icon → machine B no icon)

    /// Machine B: local copy has no icon and is older than the remote (which
    /// machine A pushed with an icon). B must pull the icon down.
    func testMachineBPullsIconFromNewerRemote() {
        let oldT = Date(timeIntervalSince1970: 1000)
        let newT = Date(timeIntervalSince1970: 2000)
        var b = makeLocalHost(name: "alpha", serverId: "srv-1", updatedAt: oldT)
        b.icon = nil
        var r = makeRemoteHost(id: "srv-1", name: "alpha", updatedAt: newT)
        r = RemoteHost(id: "srv-1", name: "alpha", hostname: "h", port: 22,
                       username: "u", authType: "key",
                       createdAt: oldT, updatedAt: newT,
                       icon: "server.rack")
        let ops = HostSyncReconciler.reconcileFullSnapshot(local: [b], remote: [r])
        XCTAssertEqual(ops, [.updateLocal(localHostId: b.id, remote: r)])
    }

    /// Machine A: just set an icon, so its local copy is newer → push up.
    func testMachineAPushesIconWhenLocalNewer() {
        let oldT = Date(timeIntervalSince1970: 1000)
        let newT = Date(timeIntervalSince1970: 2000)
        var a = makeLocalHost(name: "alpha", serverId: "srv-1", updatedAt: newT)
        a.icon = "globe.americas.fill"
        let r = makeRemoteHost(id: "srv-1", name: "alpha", updatedAt: oldT)
        let ops = HostSyncReconciler.reconcileFullSnapshot(local: [a], remote: [r])
        XCTAssertEqual(ops, [.updateRemote(localHostId: a.id, serverId: "srv-1")])
    }

    /// Equal updatedAt but icon diverges → defensive pull of the remote copy
    /// (mirrors the existing forwards-divergence safety net).
    func testEqualUpdatedAtIconDivergencePullsRemote() {
        let t = Date(timeIntervalSince1970: 1000)
        var local = makeLocalHost(name: "alpha", serverId: "srv-1", updatedAt: t)
        local.icon = nil
        let r = RemoteHost(id: "srv-1", name: "alpha", hostname: "h", port: 22,
                           username: "u", authType: "key",
                           createdAt: t, updatedAt: t, icon: "flag.fill")
        let ops = HostSyncReconciler.reconcileFullSnapshot(local: [local], remote: [r])
        XCTAssertEqual(ops, [.updateLocal(localHostId: local.id, remote: r)])
    }

    func testEqualUpdatedAtMetadataDivergencePullsRemote() {
        let t = Date(timeIntervalSince1970: 1000)
        let local = makeLocalHost(
            name: "same-name",
            serverId: "srv-1",
            updatedAt: t
        )
        let variants = [
            RemoteHost(
                id: "srv-1", name: "remote-name", hostname: "h",
                port: 22, username: "u", authType: "key",
                createdAt: t, updatedAt: t
            ),
            RemoteHost(
                id: "srv-1", name: "same-name", hostname: "remote.example",
                port: 22, username: "u", authType: "key",
                createdAt: t, updatedAt: t
            ),
            RemoteHost(
                id: "srv-1", name: "same-name", hostname: "h",
                port: 2200, username: "u", authType: "key",
                createdAt: t, updatedAt: t
            ),
            RemoteHost(
                id: "srv-1", name: "same-name", hostname: "h",
                port: 22, username: "remote-user", authType: "key",
                createdAt: t, updatedAt: t
            ),
            RemoteHost(
                id: "srv-1", name: "same-name", hostname: "h",
                port: 22, username: "u", authType: "key",
                createdAt: t, updatedAt: t,
                jumpHostServerId: "jump-server"
            ),
        ]

        for remote in variants {
            let full = HostSyncReconciler.reconcileFullSnapshot(
                local: [local],
                remote: [remote]
            )
            let delta = HostSyncReconciler.reconcileDelta(
                local: [local],
                changedHosts: [remote],
                deletedHostIDs: []
            )
            let expected = SyncOperation.updateLocal(
                localHostId: local.id,
                remote: remote
            )
            XCTAssertEqual(full, [expected])
            XCTAssertEqual(delta, [expected])
        }
    }

    func testLocalUUIDDoesNotMatchRemoteServerID() {
        let local = SSHHost(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "local",
            hostname: "local.example",
            username: "root",
            credential: .agent
        )
        let remote = makeRemoteHost(
            id: local.id.uuidString,
            name: "remote"
        )

        let ops = HostSyncReconciler.reconcileFullSnapshot(
            local: [local],
            remote: [remote]
        )

        XCTAssertEqual(ops.count, 2)
        XCTAssertTrue(ops.contains(.createRemote(localHostId: local.id)))
        XCTAssertTrue(ops.contains(.createLocal(remote: remote)))
    }

    func testDeltaMachineBPullsIconFromNewerRemote() {
        let oldT = Date(timeIntervalSince1970: 1000)
        let newT = Date(timeIntervalSince1970: 2000)
        var b = makeLocalHost(name: "alpha", serverId: "srv-1", updatedAt: oldT)
        b.icon = nil
        let r = RemoteHost(id: "srv-1", name: "alpha", hostname: "h", port: 22,
                           username: "u", authType: "key",
                           createdAt: oldT, updatedAt: newT, icon: "star.fill")
        let ops = HostSyncReconciler.reconcileDelta(
            local: [b], changedHosts: [r], deletedHostIDs: []
        )
        XCTAssertEqual(ops, [.updateLocal(localHostId: b.id, remote: r)])
    }

    // MARK: - Conflict resolution: last-write-wins

    func testRemoteNewerOverwritesLocalMetadata() {
        let oldT = Date(timeIntervalSince1970: 1000)
        let newT = Date(timeIntervalSince1970: 2000)
        let h = makeLocalHost(name: "alpha", serverId: "srv-1", updatedAt: oldT)
        let r = makeRemoteHost(id: "srv-1", name: "alpha-renamed", updatedAt: newT)
        let ops = HostSyncReconciler.reconcileFullSnapshot(local: [h], remote: [r])
        XCTAssertEqual(ops, [.updateLocal(localHostId: h.id, remote: r)])
    }

    func testLocalNewerOverwritesRemoteMetadata() {
        let oldT = Date(timeIntervalSince1970: 1000)
        let newT = Date(timeIntervalSince1970: 2000)
        let h = makeLocalHost(name: "alpha-edited", serverId: "srv-1", updatedAt: newT)
        let r = makeRemoteHost(id: "srv-1", name: "alpha", updatedAt: oldT)
        let ops = HostSyncReconciler.reconcileFullSnapshot(local: [h], remote: [r])
        XCTAssertEqual(ops, [.updateRemote(localHostId: h.id, serverId: "srv-1")])
    }

    // MARK: - Synced-then-removed

    func testSyncedHostMissingRemoteDeletesLocally() {
        // Host has serverId (was synced before) but server no longer has it.
        // Per spec §7.1.3: "Server 端没有但本地有（其它设备删了）→ 本地也删除"
        let h = makeLocalHost(name: "alpha", serverId: "srv-1")
        let ops = HostSyncReconciler.reconcileFullSnapshot(local: [h], remote: [])
        XCTAssertEqual(ops, [.deleteLocal(localHostId: h.id)])
    }

    func testUnsyncedHostNotInRemoteUploads() {
        // Host has no serverId — a brand-new local host. Server doesn't know
        // about it; we upload.
        let h = makeLocalHost(name: "alpha", serverId: nil)
        let ops = HostSyncReconciler.reconcileFullSnapshot(local: [h], remote: [])
        XCTAssertEqual(ops, [.createRemote(localHostId: h.id)])
    }

    // MARK: - Mixed cases

    func testMixedLocalUnsyncedPlusRemoteOnly() {
        let local = makeLocalHost(name: "alpha", serverId: nil)
        let remote = makeRemoteHost(id: "srv-2", name: "beta")
        let ops = HostSyncReconciler.reconcileFullSnapshot(local: [local], remote: [remote])
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
        let ops = HostSyncReconciler.reconcileFullSnapshot(local: [conflict],
                                                remote: [stale, fresh])
        XCTAssertEqual(ops.count, 2)
        XCTAssertTrue(ops.contains(.updateRemote(localHostId: conflict.id, serverId: "srv-1")))
        XCTAssertTrue(ops.contains(.createLocal(remote: fresh)))
    }

    // MARK: - Forwards divergence (Task 17)

    func test_reconciler_forwardsDifferenceCausesUpdateLocal() {
        // Equal updatedAt but forwards diverge — reconciler must still emit
        // .updateLocal so the local copy converges to the remote forwards.
        let t = Date(timeIntervalSince1970: 1000)
        var local = SSHHost(name: "h", hostname: "h.example", port: 22,
                            username: "u", credential: .password,
                            createdAt: t, updatedAt: t, forwards: [])
        local.serverId = "remote-1"
        let remote = RemoteHost(id: "remote-1", name: "h", hostname: "h.example",
                                port: 22, username: "u", authType: "key",
                                createdAt: t, updatedAt: t,
                                forwards: [
                                    PortForward(kind: .local, bindPort: 5432,
                                                remoteHost: "db", remotePort: 5432),
                                ])
        let ops = HostSyncReconciler.reconcileFullSnapshot(local: [local], remote: [remote])
        XCTAssertTrue(ops.contains(where: {
            if case .updateLocal(let id, _) = $0, id == local.id { return true }
            return false
        }))
    }

    func test_reconciler_delta_forwardsDifferenceCausesUpdateLocal() {
        let t = Date(timeIntervalSince1970: 1000)
        var local = SSHHost(name: "h", hostname: "h.example", port: 22,
                            username: "u", credential: .password,
                            createdAt: t, updatedAt: t, forwards: [])
        local.serverId = "remote-1"
        let remote = RemoteHost(id: "remote-1", name: "h", hostname: "h.example",
                                port: 22, username: "u", authType: "key",
                                createdAt: t, updatedAt: t,
                                forwards: [
                                    PortForward(kind: .remote, bindPort: 8080,
                                                remoteHost: "localhost", remotePort: 80),
                                ])
        let ops = HostSyncReconciler.reconcileDelta(
            local: [local], changedHosts: [remote], deletedHostIDs: []
        )
        XCTAssertTrue(ops.contains(where: {
            if case .updateLocal(let id, _) = $0, id == local.id { return true }
            return false
        }))
    }

    func test_reconciler_equalForwardsAndUpdatedAtIsNoOp() {
        // Sanity: equal updatedAt AND equal forwards → no op.
        let t = Date(timeIntervalSince1970: 1000)
        let fwd = [PortForward(kind: .local, bindPort: 9000,
                                remoteHost: "svc", remotePort: 9000)]
        var local = SSHHost(name: "h", hostname: "h.example", port: 22,
                            username: "u", credential: .password,
                            createdAt: t, updatedAt: t, forwards: fwd)
        local.serverId = "remote-1"
        let remote = RemoteHost(id: "remote-1", name: "h", hostname: "h.example",
                                port: 22, username: "u", authType: "key",
                                createdAt: t, updatedAt: t,
                                forwards: fwd)
        let ops = HostSyncReconciler.reconcileFullSnapshot(local: [local], remote: [remote])
        XCTAssertTrue(ops.isEmpty)
    }

    func test_reconciler_neverEmitsUpdateRemoteCredentials() {
        // Mix of local-only, remote-only, and mismatched updatedAt entries.
        let local = [
            makeLocalHost(name: "A", serverId: nil),
            makeLocalHost(name: "B", serverId: "rec-1", updatedAt: Date(timeIntervalSince1970: 100))
        ]
        let remote = [
            RemoteHost(id: "rec-1", name: "B-renamed", hostname: "h", port: 22,
                       username: "u", authType: "password",
                       createdAt: Date(timeIntervalSince1970: 0),
                       updatedAt: Date(timeIntervalSince1970: 200))
        ]
        let opsFull = HostSyncReconciler.reconcileFullSnapshot(local: local, remote: remote)
        let opsDelta = HostSyncReconciler.reconcileDelta(local: local, changedHosts: remote, deletedHostIDs: [])
        for op in opsFull + opsDelta {
            if case .updateRemoteCredentials = op { XCTFail("reconciler must not emit .updateRemoteCredentials") }
        }
    }
}

final class HostSyncReconcilerDeltaTests: XCTestCase {
    func testDeltaUpsertCreatesLocal() {
        let r = RemoteHost(id: "S1", name: "x", hostname: "h", port: 22,
                           username: "u", authType: "password",
                           createdAt: Date(timeIntervalSince1970: 100),
                           updatedAt: Date(timeIntervalSince1970: 100))
        let ops = HostSyncReconciler.reconcileDelta(
            local: [], changedHosts: [r], deletedHostIDs: []
        )
        XCTAssertEqual(ops, [.createLocal(remote: r)])
    }

    func testDeltaUpsertUpdatesNewerRemote() {
        let local = makeLocalSynced(serverId: "S1", updatedAt: 100)
        let r = RemoteHost(id: "S1", name: "x", hostname: "h", port: 22,
                           username: "u", authType: "password",
                           createdAt: Date(timeIntervalSince1970: 200),
                           updatedAt: Date(timeIntervalSince1970: 200))
        let ops = HostSyncReconciler.reconcileDelta(
            local: [local], changedHosts: [r], deletedHostIDs: []
        )
        XCTAssertEqual(ops, [.updateLocal(localHostId: local.id, remote: r)])
    }

    func testDeltaUpsertPushesNewerLocal() {
        let local = makeLocalSynced(serverId: "S1", updatedAt: 200)
        let remote = RemoteHost(
            id: "S1", name: "x", hostname: "h", port: 22,
            username: "u", authType: "password",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        let ops = HostSyncReconciler.reconcileDelta(
            local: [local],
            changedHosts: [remote],
            deletedHostIDs: []
        )

        XCTAssertEqual(
            ops,
            [.updateRemote(localHostId: local.id, serverId: "S1")]
        )
    }

    func testDeltaDeleteRemovesLocal() {
        let local = makeLocalSynced(serverId: "S1", updatedAt: 100)
        let ops = HostSyncReconciler.reconcileDelta(
            local: [local], changedHosts: [], deletedHostIDs: ["S1"]
        )
        XCTAssertEqual(ops, [.deleteLocal(localHostId: local.id)])
    }

    func testDeltaIgnoresDeletionForUnknownServerId() {
        let ops = HostSyncReconciler.reconcileDelta(
            local: [], changedHosts: [], deletedHostIDs: ["missing"]
        )
        XCTAssertTrue(ops.isEmpty)
    }

    private func makeLocalSynced(serverId: String, updatedAt: TimeInterval) -> SSHHost {
        var h = SSHHost(name: "n", hostname: "h", port: 22, username: "u",
                        credential: .agent,
                        createdAt: Date(timeIntervalSince1970: updatedAt),
                        updatedAt: Date(timeIntervalSince1970: updatedAt))
        h.serverId = serverId
        return h
    }
}
