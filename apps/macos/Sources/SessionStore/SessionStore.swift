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

    public let askpassPath: String
    public let knownHostsCaterm: String
    public let knownHostsUser: String
    public let accessGroup: String?

    public init(askpassPath: String, knownHostsCaterm: String,
                knownHostsUser: String, accessGroup: String?) {
        self.askpassPath = askpassPath
        self.knownHostsCaterm = knownHostsCaterm
        self.knownHostsUser = knownHostsUser
        self.accessGroup = accessGroup
    }

    public func openTab(host: SSHHost) -> UUID {
        let tab = Tab(host: host)
        tabs.append(tab)
        return tab.id
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
