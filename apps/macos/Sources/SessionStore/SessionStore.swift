import Combine
import Foundation
import KeychainStore
import SSHCommandBuilder
import ServerSyncClient

// We deliberately import Combine (not SwiftUI/AppKit) here so the public `Host`
// from SSHCommandBuilder doesn't collide with Foundation.NSHost. ObservableObject
// lives in Combine. UI types (Caterm executable target) wrap us via @StateObject.

@MainActor
public final class SessionStore: ObservableObject {
    public struct Tab: Identifiable {
        public let id: UUID
        public var host: SSHHost
        public var state: ConnectionState
        public var hadConnected: Bool = false
        public var reconnectAttempts: Int = 0
        public var lastFailure: FailureKind?
        public var surfaceGeneration: Int = 0
        public init(host: SSHHost) {
            self.id = UUID()
            self.host = host
            self.state = .idle
        }
    }

    @Published public private(set) var tabs: [Tab] = []
    /// User's saved hosts. Persisted to `hostsURL` (JSON). Use the
    /// `addHost / updateHost / deleteHost` methods to mutate — direct mutation
    /// won't trigger persistence.
    @Published public private(set) var hosts: [SSHHost] = []

    public let askpassPath: String
    public let knownHostsCaterm: String
    public let knownHostsUser: String
    public let accessGroup: String?
    public let hostsURL: URL
    public let keychain: KeychainStore

    /// Per-host secret kind. Maps to the keychain account suffix
    /// (`<hostId>.<rawValue>`) so different secrets per host don't collide.
    public enum SecretKind: String {
        case password
        case keyPassphrase
    }

    public init(askpassPath: String, knownHostsCaterm: String,
                knownHostsUser: String, accessGroup: String?,
                hostsURL: URL, keychain: KeychainStore) {
        self.askpassPath = askpassPath
        self.knownHostsCaterm = knownHostsCaterm
        self.knownHostsUser = knownHostsUser
        self.accessGroup = accessGroup
        self.hostsURL = hostsURL
        self.keychain = keychain
        do {
            self.hosts = try HostPersistence.load(from: hostsURL)
        } catch {
            self.hosts = []
        }
    }

    // MARK: - Host CRUD

    public func addHost(_ host: SSHHost) throws {
        hosts.append(host)
        try HostPersistence.save(hosts, to: hostsURL)
    }

    public func updateHost(_ host: SSHHost) throws {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        var updated = host
        updated.updatedAt = Date()
        hosts[idx] = updated
        try HostPersistence.save(hosts, to: hostsURL)
    }

    public func deleteHost(id: UUID) throws {
        hosts.removeAll { $0.id == id }
        try HostPersistence.save(hosts, to: hostsURL)
        // Best-effort keychain cleanup; Task 1.7 expands this with explicit kind enumeration.
        try? keychain.deleteAll(prefix: "\(id.uuidString).")
    }

    /// Persist a per-host secret (password or key passphrase) to Keychain
    /// under the account `<hostId>.<kind>`.
    public func setHostSecret(_ secret: String, hostId: UUID, kind: SecretKind) throws {
        try keychain.set(account: "\(hostId.uuidString).\(kind.rawValue)", secret: secret)
    }

    // MARK: - Tabs

    public func openTab(host: SSHHost) -> UUID {
        let tab = Tab(host: host)
        tabs.append(tab)
        return tab.id
    }

    /// Remove a tab from the store. The actual libghostty surface destruction
    /// (and resulting SIGHUP to the ssh subprocess) happens automatically when
    /// SwiftUI removes the corresponding `GhosttySurfaceNSView` from its view
    /// hierarchy — `deinit` calls `ghostty_surface_free`. This method only
    /// keeps the store in sync with the UI.
    public func closeTab(tabId: UUID) {
        tabs.removeAll { $0.id == tabId }
    }

    /// Build the (commandString, env) pair for a given tab.
    public func surfaceConfig(for tabId: UUID) -> (command: String, env: [(String, String)])? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        let cmd = SSHCommandBuilder.build(
            host: tab.host,
            askpassPath: askpassPath,
            knownHostsCaterm: knownHostsCaterm,
            knownHostsUser: knownHostsUser
        )
        var env = cmd.env
        if let accessGroup { env.append(("CATERM_ACCESS_GROUP", accessGroup)) }
        return (cmd.command, env)
    }

    public func markConnecting(tabId: UUID) {
        update(tabId) { $0.state = .connecting(startedAt: Date()) }
    }

    public func markConnected(tabId: UUID) {
        update(tabId) {
            $0.state = .connected(connectedAt: Date())
            $0.hadConnected = true
            $0.reconnectAttempts = 0
        }
    }

    public func markChildExited(tabId: UUID, exitCode: Int32) {
        update(tabId) { tab in
            let kind = FailureKind.classify(exitCode: exitCode,
                                            hadConnected: tab.hadConnected)
            tab.lastFailure = kind
            let attempt = tab.reconnectAttempts + 1
            if ReconnectScheduler.shouldReconnect(failureKind: kind, attempt: attempt) {
                tab.reconnectAttempts = attempt
                let delay = ReconnectScheduler.backoff(attempt: attempt)
                let nextRetry = Date().addingTimeInterval(delay)
                tab.state = .reconnecting(attempt: attempt, nextRetryAt: nextRetry)
                scheduleReconnect(tabId: tabId, after: delay)
            } else {
                tab.state = .failed(kind)
            }
        }
    }

    private func scheduleReconnect(tabId: UUID, after seconds: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self else { return }
            self.update(tabId) { $0.surfaceGeneration += 1; $0.state = .connecting(startedAt: Date()) }
        }
    }

    private func update(_ tabId: UUID, _ mutate: (inout Tab) -> Void) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        var tab = tabs[idx]
        mutate(&tab)
        tabs[idx] = tab
    }

    // MARK: - Sync support (v1.1)

    /// True when this host has no usable local credential. Pulled hosts always
    /// fall here (no Keychain item under their local UUID). Local-only `.agent`
    /// hosts are always false. See spec §7.1.2 needsCredentialSetup.
    public func needsCredentialSetup(_ host: SSHHost) -> Bool {
        switch host.credential {
        case .agent:
            return false
        case .password:
            return (try? keychain.get(account: "\(host.id.uuidString).password")) == nil
        case let .keyFile(keyPath, hasPassphrase):
            if !FileManager.default.fileExists(atPath: keyPath) { return true }
            if hasPassphrase {
                return (try? keychain.get(account: "\(host.id.uuidString).keyPassphrase")) == nil
            }
            return false
        }
    }

    /// Replace the `serverId` of an existing host in-memory and persist.
    public func setServerId(_ serverId: String, for hostId: UUID) throws {
        guard let idx = hosts.firstIndex(where: { $0.id == hostId }) else { return }
        hosts[idx].serverId = serverId
        hosts[idx].updatedAt = Date()
        try HostPersistence.save(hosts, to: hostsURL)
    }

    /// Replace metadata fields (name/hostname/port/username/updatedAt) without
    /// touching credential or serverId. Used when a remote update lands.
    public func applyRemoteMetadata(localHostId: UUID, remote: RemoteHost) throws {
        guard let idx = hosts.firstIndex(where: { $0.id == localHostId }) else { return }
        hosts[idx].name = remote.name
        hosts[idx].hostname = remote.hostname
        hosts[idx].port = remote.port
        hosts[idx].username = remote.username
        hosts[idx].updatedAt = remote.updatedAt
        try HostPersistence.save(hosts, to: hostsURL)
    }

    /// Insert a host fetched from the server. Allocates a fresh local UUID,
    /// stamps `serverId` from `remote.id`, defaults credential to `.password`
    /// (so first connect prompts the user — see needsCredentialSetup).
    public func addRemoteHost(_ remote: RemoteHost) throws {
        let h = SSHHost(
            id: UUID(),
            serverId: remote.id,
            name: remote.name, hostname: remote.hostname,
            port: remote.port, username: remote.username,
            credential: .password,
            createdAt: remote.createdAt, updatedAt: remote.updatedAt
        )
        hosts.append(h)
        try HostPersistence.save(hosts, to: hostsURL)
    }

    /// Replace the credential overlay for an existing host. Does NOT bump
    /// `updatedAt` — credential is a device-local concept that never propagates
    /// to the server, so it must not trigger reconciler `.updateRemote` ops.
    ///
    /// Atomicity: persists to a local copy first; only assigns to `self.hosts`
    /// after `HostPersistence.save` returns. A disk-write failure throws
    /// without mutating in-memory state, so callers can treat the call as
    /// all-or-nothing for SessionStore-side state.
    public func setCredentialOnly(_ source: CredentialSource,
                                  for hostId: UUID) throws {
        guard let idx = hosts.firstIndex(where: { $0.id == hostId }) else { return }
        var updated = hosts
        updated[idx].credential = source
        try HostPersistence.save(updated, to: hostsURL)
        hosts = updated
    }
}
