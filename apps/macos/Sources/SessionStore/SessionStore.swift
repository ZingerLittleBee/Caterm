import Combine
import Foundation
import KeychainStore
import SSHCommandBuilder
import ServerSyncClient

// We deliberately import Combine (not SwiftUI/AppKit) here so the public `Host`
// from SSHCommandBuilder doesn't collide with Foundation.NSHost. ObservableObject
// lives in Combine. UI types (Caterm executable target) wrap us via @StateObject.

/// Minimal protocol covering the ControlMaster lifecycle hooks SessionStore
/// needs. Declared in SessionStore to avoid taking a hard dependency on
/// FileTransferStore. The `Caterm` target supplies the real conformance via
/// an extension on `ControlMasterManager`.
///
/// `register` is synchronous and main-actor-isolated: it just records the
/// (hostId, destination) tuple so a subsequent `isAlive(hostId:)` check
/// (in `RemoteFileSystem`) and `tearDown(hostId:)` call (in
/// `applicationWillTerminate`) have something to act on. Without it, the
/// file drawer always reports "Reconnect host to browse files".
public protocol ControlMasterTearDowning: Sendable {
    @MainActor func register(hostId: UUID, destination: String)
    func tearDown(hostId: UUID) async
    func tearDownAll() async
}

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

    /// Combine signal for "user-driven local hosts mutation just persisted".
    /// `HostSyncStore` debounces this to drive auto-sync. Only `addHost`,
    /// `updateHost`, and `deleteHost` emit — credential-only changes and
    /// the apply ops from a sync pass deliberately do NOT (spec §3.2).
    private let mutationsForSyncSubject = PassthroughSubject<Void, Never>()
    public var mutationsForSync: AnyPublisher<Void, Never> {
        mutationsForSyncSubject.eraseToAnyPublisher()
    }

    public let askpassPath: String
    public let knownHostsCaterm: String
    public let knownHostsUser: String
    public let accessGroup: String?
    public let hostsURL: URL
    public let keychain: KeychainStore

    /// Optional ControlMaster manager used to tear down per-host shared SSH
    /// connections when the last tab for a host closes (after a grace
    /// period). Tests can pass a spy implementing the protocol; production
    /// passes `ControlMasterManager.shared` from the Caterm target.
    private let controlMasterManager: ControlMasterTearDowning?

    /// Pending teardown work items keyed by host id. We use
    /// `DispatchWorkItem` so a re-opened tab for the same host can cancel
    /// the scheduled teardown via `cancel()`.
    private var teardownWorkItems: [UUID: DispatchWorkItem] = [:]

	private let preflight: PreflightProbing

	/// Per-tab attempt token — bumped on every `startConnection` invocation
	/// so a stale async probe outcome from a cancelled retry cannot mutate
	/// the current tab state.
	private var connectionAttempts: [UUID: UInt64] = [:]

	/// In-flight `startConnection` Tasks per tab. Tests use
	/// `awaitConnectionAttempt(tabId:)` to await them deterministically.
	private var pendingStartTasks: [UUID: Task<Void, Never>] = [:]

    /// Grace period in seconds before tearing down ControlMaster after the
    /// last tab for a host closes. Internal/mutable so tests can override
    /// it through `@testable import` (default 30s in production).
    var teardownGraceSeconds: Double = 30

    /// Per-host secret kind. Maps to the keychain account suffix
    /// (`<hostId>.<rawValue>`) so different secrets per host don't collide.
    public enum SecretKind: String {
        case password
        case keyPassphrase
    }

    public init(askpassPath: String, knownHostsCaterm: String,
                knownHostsUser: String, accessGroup: String?,
                hostsURL: URL, keychain: KeychainStore,
                controlMasterManager: ControlMasterTearDowning? = nil,
                preflight: PreflightProbing = Preflight()) {
        self.askpassPath = askpassPath
        self.knownHostsCaterm = knownHostsCaterm
        self.knownHostsUser = knownHostsUser
        self.accessGroup = accessGroup
        self.hostsURL = hostsURL
        self.keychain = keychain
        self.controlMasterManager = controlMasterManager
        self.preflight = preflight
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
        mutationsForSyncSubject.send()
    }

    public func updateHost(_ host: SSHHost) throws {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        var updated = host
        updated.updatedAt = Date()
        hosts[idx] = updated
        try HostPersistence.save(hosts, to: hostsURL)
        mutationsForSyncSubject.send()
    }

    public func deleteHost(id: UUID) throws {
        hosts.removeAll { $0.id == id }
        try HostPersistence.save(hosts, to: hostsURL)
        // Best-effort keychain cleanup; Task 1.7 expands this with explicit kind enumeration.
        try? keychain.deleteAll(prefix: "\(id.uuidString).")
        mutationsForSyncSubject.send()
    }

    /// Persist a per-host secret (password or key passphrase) to Keychain
    /// under the account `<hostId>.<kind>`.
    public func setHostSecret(_ secret: String, hostId: UUID, kind: SecretKind) throws {
        try keychain.set(account: "\(hostId.uuidString).\(kind.rawValue)", secret: secret)
    }

    // MARK: - Tabs

    public func openTab(host: SSHHost) -> UUID {
        // Re-opening a tab for the same host within the grace window
        // cancels any pending ControlMaster teardown so we keep reusing
        // the existing shared connection.
        teardownWorkItems[host.id]?.cancel()
        teardownWorkItems.removeValue(forKey: host.id)
        // Make the (hostId → destination) mapping live in the
        // ControlMasterManager so `isAlive(hostId:)` can check the
        // socket and `tearDown` knows what `ssh -O exit` target to use.
        // Idempotent: re-registering the same destination is a no-op.
        let destination = "\(host.username)@\(host.hostname)"
        controlMasterManager?.register(hostId: host.id, destination: destination)
        let tab = Tab(host: host)
        tabs.append(tab)
        startConnection(tabId: tab.id)            // NEW
        return tab.id
    }

    /// Remove a tab from the store. The actual libghostty surface destruction
    /// (and resulting SIGHUP to the ssh subprocess) happens automatically when
    /// SwiftUI removes the corresponding `GhosttySurfaceNSView` from its view
    /// hierarchy — `deinit` calls `ghostty_surface_free`. This method only
    /// keeps the store in sync with the UI.
    ///
    /// When the closed tab was the LAST tab referencing a given host, we
    /// schedule a delayed ControlMaster teardown for that host. The delay
    /// (`teardownGraceSeconds`, 30s in production) gives users a chance
    /// to immediately re-open a tab to the same host without paying the
    /// full SSH handshake cost again.
    public func closeTab(tabId: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        // Cancel any in-flight startConnection probe for this tab so we don't
        // leak the underlying NWConnection while the user moves on.
        pendingStartTasks.removeValue(forKey: tabId)?.cancel()
        connectionAttempts.removeValue(forKey: tabId)
        let hostId = tabs[idx].host.id
        tabs.remove(at: idx)
        let stillReferenced = tabs.contains { $0.host.id == hostId }
        if !stillReferenced {
            scheduleTeardown(hostId: hostId)
        }
    }

    private func scheduleTeardown(hostId: UUID) {
        guard let manager = controlMasterManager else { return }
        // Replace any prior pending teardown for this host.
        teardownWorkItems[hostId]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await manager.tearDown(hostId: hostId)
                self?.teardownWorkItems.removeValue(forKey: hostId)
            }
        }
        teardownWorkItems[hostId] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + teardownGraceSeconds,
                                      execute: item)
    }

    /// Build the (commandString, env) pair for a given tab. `installTerminfo`
    /// (v1.6) drives whether the resulting command appends an inline
    /// terminfo-install wrapper and a `TERM=xterm-ghostty` env override.
    public func surfaceConfig(for tabId: UUID, installTerminfo: Bool = false) -> (command: String, env: [(String, String)])? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        let cmd = SSHCommandBuilder.build(
            host: tab.host,
            askpassPath: askpassPath,
            knownHostsCaterm: knownHostsCaterm,
            knownHostsUser: knownHostsUser,
            installTerminfo: installTerminfo
        )
        var env = cmd.env
        if let accessGroup { env.append(("CATERM_ACCESS_GROUP", accessGroup)) }
        return (cmd.command, env)
    }

    public func hostId(for tabId: UUID) -> UUID? {
        tabs.first(where: { $0.id == tabId })?.host.id
    }

	/// Single entry point for "kick off connection for this tab". Idempotent:
	/// callers (`openTab`, `retryTab`, reconnect timer) can all invoke; the
	/// attempt token guards stale results.
	public func startConnection(tabId: UUID) {
		// Cancel any in-flight probe for this tab — its outcome would be
		// discarded by the attempt-token guard anyway, but cancellation
		// releases the underlying NWConnection and stops a pending Preflight.probe
		// from holding a socket open for the full 5s timeout.
		pendingStartTasks[tabId]?.cancel()
		let task = Task { @MainActor [weak self] in
			guard let self else { return }
			await self.runConnection(tabId: tabId)
		}
		pendingStartTasks[tabId] = task
	}

	private func runConnection(tabId: UUID) async {
		guard let host = tabs.first(where: { $0.id == tabId })?.host else { return }
		let token = (connectionAttempts[tabId] ?? 0) &+ 1
		connectionAttempts[tabId] = token

		guard (1...65535).contains(host.port) else {
			applyIfCurrent(tabId: tabId, token: token) { tab in
				tab.state = .failed(.networkUnreachable(.invalidPort(host.port)))
			}
			if connectionAttempts[tabId] == token {
				pendingStartTasks.removeValue(forKey: tabId)
			}
			return
		}

		applyIfCurrent(tabId: tabId, token: token) { tab in
			tab.state = .preflight(startedAt: Date())
		}

		let outcome = await preflight.probe(
			host: host.hostname,
			port: UInt16(host.port),
			timeout: 5
		)

		applyIfCurrent(tabId: tabId, token: token) { tab in
			switch outcome {
			case .ok:
				tab.surfaceGeneration += 1
				tab.state = .authenticating(startedAt: Date())
			case .failed(let reason):
				tab.state = .failed(.networkUnreachable(reason))
			}
		}

		// Clear our pending-task entry only if we are still the current attempt.
		// If a newer startConnection() ran, it has already replaced the entry,
		// and we must not stomp on it.
		if connectionAttempts[tabId] == token {
			pendingStartTasks.removeValue(forKey: tabId)
		}
	}

	private func applyIfCurrent(tabId: UUID, token: UInt64,
	                            _ mutate: (inout Tab) -> Void) {
		guard connectionAttempts[tabId] == token else { return }
		update(tabId, mutate)
	}

	public func retryTab(tabId: UUID) {
		update(tabId) {
			$0.lastFailure = nil
			$0.state = .idle
		}
		startConnection(tabId: tabId)
	}

	/// Test-only: await the most recent in-flight `startConnection` Task.
	/// Marked public so XCTest can call it; production code never needs to.
	public func awaitConnectionAttempt(tabId: UUID) async {
		if let t = pendingStartTasks[tabId] {
			await t.value
		}
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
            // Bump surfaceGeneration synchronously here so SwiftUI tears down
            // the dead libghostty surface immediately, even on unhealthy
            // networks where the probe in startConnection will fail. The
            // success-path bump inside runConnection is harmless — the id
            // changes either way.
            self.update(tabId) { $0.surfaceGeneration += 1 }
            // Route through startConnection so the reconnect attempt also gets
            // TCP preflight + typed networkUnreachable failure if the network
            // is still down.
            self.startConnection(tabId: tabId)
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

    /// Replace metadata fields (name/hostname/port/username/updatedAt/jumpHostServerId)
    /// without touching credential or serverId. Used when a remote update lands.
    public func applyRemoteMetadata(localHostId: UUID, remote: RemoteHost) throws {
        guard let idx = hosts.firstIndex(where: { $0.id == localHostId }) else { return }
        hosts[idx].name = remote.name
        hosts[idx].hostname = remote.hostname
        hosts[idx].port = remote.port
        hosts[idx].username = remote.username
        hosts[idx].updatedAt = remote.updatedAt
        hosts[idx].jumpHostServerId = remote.jumpHostServerId
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
            createdAt: remote.createdAt, updatedAt: remote.updatedAt,
            jumpHostServerId: remote.jumpHostServerId
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

	/// Plan C: single credential-mutation entry point.
	/// Atomic ordering: Keychain writes (password / keyPassphrase) →
	/// host.credential update + dirty=true → HostPersistence.save → post
	/// notification. ManagedKeyStore writes for `secrets.privateKeyBytes`
	/// happen on the caller side (SessionStore has no dependency on
	/// ManagedKeyStore — avoids module graph entanglement). Callers must
	/// have already written private-key bytes via ManagedKeyStore before
	/// calling, and the `credentialSource` they pass already encodes the
	/// resulting managedPath.
	public func setHostCredentialMaterial(
		secrets: HostSecrets,
		credentialSource: CredentialSource,
		for hostId: UUID
	) throws {
		if let pw = secrets.password {
			guard let s = String(data: pw, encoding: .utf8) else { throw KeychainError.decodeFailed }
			try keychain.set(account: "\(hostId.uuidString).password", secret: s)
		}
		if let pp = secrets.passphrase {
			guard let s = String(data: pp, encoding: .utf8) else { throw KeychainError.decodeFailed }
			try keychain.set(account: "\(hostId.uuidString).keyPassphrase", secret: s)
		}
		guard let idx = hosts.firstIndex(where: { $0.id == hostId }) else { return }
		var updated = hosts
		updated[idx].credential = credentialSource
		updated[idx].credentialMaterialDirty = true
		try HostPersistence.save(updated, to: hostsURL)
		hosts = updated

		NotificationCenter.default.post(
			name: .catermHostCredentialMaterialChanged,
			object: nil,
			userInfo: [CatermHostCredentialMaterialChangedKeys.hostId: hostId]
		)
	}

	public func clearCredentialMaterialDirty(_ hostId: UUID) throws {
		guard let idx = hosts.firstIndex(where: { $0.id == hostId }) else { return }
		guard hosts[idx].credentialMaterialDirty else { return }  // idempotent
		var updated = hosts
		updated[idx].credentialMaterialDirty = false
		try HostPersistence.save(updated, to: hostsURL)
		hosts = updated
	}

	/// Plan C pull-side credential application. Caller (HostSyncStore)
	/// decrypts ciphertext and (if private-key bytes present) has already
	/// called `ManagedKeyStore.write` to obtain `managedKeyPath`.
	/// Does NOT set credentialMaterialDirty — the bytes came FROM the
	/// remote, so re-pushing would be a useless write loop.
	public func applyRemoteCredential(
		decryptedPassword: Data?,
		decryptedPassphrase: Data?,
		decryptedPrivateKey: Data?,
		managedKeyPath: String?,
		for hostId: UUID
	) throws {
		guard let idx = hosts.firstIndex(where: { $0.id == hostId }) else { return }

		if let pw = decryptedPassword {
			guard let s = String(data: pw, encoding: .utf8) else { throw KeychainError.decodeFailed }
			try keychain.set(account: "\(hostId.uuidString).password", secret: s)
		}
		if let pp = decryptedPassphrase {
			guard let s = String(data: pp, encoding: .utf8) else { throw KeychainError.decodeFailed }
			try keychain.set(account: "\(hostId.uuidString).keyPassphrase", secret: s)
		}

		var updated = hosts
		if decryptedPrivateKey != nil, let path = managedKeyPath {
			updated[idx].credential = .keyFile(keyPath: path, hasPassphrase: decryptedPassphrase != nil)
		} else if decryptedPassword != nil {
			updated[idx].credential = .password
		}  // else: leave existing credential alone (e.g., .agent)
		try HostPersistence.save(updated, to: hostsURL)
		hosts = updated
	}
}
