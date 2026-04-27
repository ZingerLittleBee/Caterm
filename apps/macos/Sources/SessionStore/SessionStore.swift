import Combine
import Foundation
import KeychainStore
import SSHCommandBuilder

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
        }
    }

    public func markChildExited(tabId: UUID, exitCode: Int32) {
        update(tabId) { tab in
            let kind = FailureKind.classify(exitCode: exitCode,
                                            hadConnected: tab.hadConnected)
            tab.state = .failed(kind)
        }
    }

    private func update(_ tabId: UUID, _ mutate: (inout Tab) -> Void) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        var tab = tabs[idx]
        mutate(&tab)
        tabs[idx] = tab
    }
}
