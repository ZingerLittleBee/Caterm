import Combine
import Foundation
import HostRepositoryCore
import KeychainStore
import ManagedKeyStore
import os
import SSHCommandBuilder
import SSHCredentialContract
import ServerSyncClient
import SessionHistory

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
	private static let log = Logger(
		subsystem: "com.caterm.app",
		category: "session-store"
	)

    public struct Tab: Identifiable {
        public let id: UUID
        public var host: SSHHost
        public var state: ConnectionState
        public var hadConnected: Bool = false
        public var reconnectAttempts: Int = 0
        public var lastFailure: FailureKind?
        public var surfaceGeneration: Int = 0
        /// Resolved jump-host chain in dial order (deepest ancestor first).
        /// Empty when the target has no `jumpHostServerId`. Populated at
        /// `openTab` time so `runConnection` and `surfaceConfig` can use it.
        public var resolvedChain: [SSHHost] = []
        /// URL of the per-session ssh_config written by `SSHCommandBuilder.build`
        /// for chain connections. Nil for direct (no-jump) connections. Cleaned
        /// up by `closeTab` and `markChildExited`.
        public var sshConfigURL: URL? = nil
        /// Full `SSHCommandBuilder.Output` captured from the chain-aware build
        /// in `runConnection`. Non-nil only when `resolvedChain` is non-empty
        /// and the build succeeded. `surfaceConfig` returns its (command, env)
        /// directly so the chain feature works end-to-end.
        public var chainOutput: SSHCommandBuilder.Output? = nil
        /// Whether to install terminfo on connect (v1.6 feature). Snapshotted
        /// at `openTab` time so `runConnection` passes the correct value to
        /// `SSHCommandBuilder.build` when building chain commands.
        public var installTerminfo: Bool = false
		/// Authentication behavior captured when the tab opens. Saved hosts use
		/// their configured credential; one-time connections let OpenSSH prompt.
		public var authenticationMode: SSHAuthenticationMode = .configuredCredential
		public var historyEntryID: UUID?
        public init(host: SSHHost) {
            self.id = UUID()
            self.host = host
            self.state = .idle
        }
        /// Convenience initialiser for pre-failed tabs created synchronously
        /// in `openTab` when chain resolution or credential pre-check fails.
        init(
			id: UUID,
			host: SSHHost,
			failedWith kind: FailureKind,
			historyEntryID: UUID? = nil
		) {
            self.id = id
            self.host = host
            self.state = .failed(kind)
			self.historyEntryID = historyEntryID
        }
        /// Convenience initialiser for happy-path tabs that carry a pre-resolved chain.
        init(
			id: UUID,
			host: SSHHost,
			resolvedChain: [SSHHost],
			installTerminfo: Bool = false,
			authenticationMode: SSHAuthenticationMode = .configuredCredential,
			historyEntryID: UUID? = nil
		) {
            self.id = id
            self.host = host
            self.state = .idle
            self.resolvedChain = resolvedChain
            self.installTerminfo = installTerminfo
			self.authenticationMode = authenticationMode
			self.historyEntryID = historyEntryID
        }
    }

    @Published public private(set) var tabs: [Tab] = []
    /// User's saved hosts. Persisted to `hostsURL` (JSON). Use the
    /// `addHost / updateHost / deleteHost` methods to mutate — direct mutation
    /// won't trigger persistence.
    @Published public private(set) var hosts: [SSHHost] = []
	@Published public private(set) var credentialAvailabilityRevision: UInt64 = 0

	public struct SkippedForwardNotice: Identifiable, Equatable, Sendable {
		public let id: UUID
		public let tabId: UUID
		public let hostId: UUID
		public let forward: PortForward
		public let reason: PortForward.BindFailureReason
		public let timestamp: Date

		public init(tabId: UUID, hostId: UUID, forward: PortForward,
		            reason: PortForward.BindFailureReason,
		            id: UUID = UUID(), timestamp: Date = Date()) {
			self.id = id
			self.tabId = tabId
			self.hostId = hostId
			self.forward = forward
			self.reason = reason
			self.timestamp = timestamp
		}
	}

	@Published public private(set) var skippedForwardNotices: [SkippedForwardNotice] = []

	public func clearSkippedForwardNotices(forTab tabId: UUID? = nil) {
		if let tabId {
			skippedForwardNotices.removeAll { $0.tabId == tabId }
		} else {
			skippedForwardNotices.removeAll()
		}
	}

    /// Combine signal for "user-driven local hosts mutation just persisted".
    /// `HostSyncStore` debounces this to drive auto-sync. Only `addHost`,
    /// `updateHost`, `updateHosts`, and `deleteHost` emit — credential-only
    /// changes and the apply ops from a sync pass deliberately do NOT
    /// (spec §3.2).
    private let mutationsForSyncSubject = PassthroughSubject<Void, Never>()
    public var mutationsForSync: AnyPublisher<Void, Never> {
        mutationsForSyncSubject.eraseToAnyPublisher()
    }

    public let askpassPath: String
    public let knownHostsCaterm: String
    public let knownHostsUser: String
    public let accessGroup: String?
    public let hostsURL: URL
	let keychain: KeychainStore
	public let credentialMaterialStore: SessionCredentialMaterialStore
	let managedKeyStore: ManagedKeyStore
	private var hostDeletionOutbox: HostDeletionOutbox

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
	private let configSink: SSHConfigSink
	private let historyRecorder: SessionHistoryRecording?

	/// Per-tab attempt token — bumped on every `startConnection` invocation
	/// so a stale async probe outcome from a cancelled retry cannot mutate
	/// the current tab state.
	private var connectionAttempts: [UUID: UInt64] = [:]

	/// In-flight `startConnection` Tasks per tab. Tests use
	/// `awaitConnectionAttempt(tabId:)` to await them deterministically.
	private var pendingStartTasks: [UUID: Task<Void, Never>] = [:]
	private var pendingReconnectTasks: [UUID: Task<Void, Never>] = [:]
	private var reconnectScheduleTokens: [UUID: UInt64] = [:]

    /// Grace period in seconds before tearing down ControlMaster after the
    /// last tab for a host closes. Internal/mutable so tests can override
    /// it through `@testable import` (default 30s in production).
    var teardownGraceSeconds: Double = 30

    /// Per-host secret kind. Maps to the keychain account suffix
    /// (`<hostId>.<rawValue>`) so different secrets per host don't collide.
	enum SecretKind {
        case password
        case keyPassphrase

		var credentialKind: SSHCredentialKind {
			switch self {
			case .password: return .password
			case .keyPassphrase: return .keyPassphrase
			}
		}
    }

	public convenience init(
		askpassPath: String,
		knownHostsCaterm: String,
		knownHostsUser: String,
		accessGroup: String?,
		hostsURL: URL,
		keychain: KeychainStore,
		controlMasterManager: ControlMasterTearDowning? = nil,
		preflight: PreflightProbing = Preflight(),
		configSink: SSHConfigSink = CatermSSHConfigSink(),
		managedKeyStore: ManagedKeyStore = ManagedKeyStore(),
		historyRecorder: SessionHistoryRecording? = nil
	) {
		self.init(
			askpassPath: askpassPath,
			knownHostsCaterm: knownHostsCaterm,
			knownHostsUser: knownHostsUser,
			accessGroup: accessGroup,
			hostsURL: hostsURL,
			keychain: keychain,
			controlMasterManager: controlMasterManager,
			preflight: preflight,
			configSink: configSink,
			managedKeyStore: managedKeyStore,
			credentialMaterialStore: nil,
			historyRecorder: historyRecorder
		)
	}

	init(
		askpassPath: String,
		knownHostsCaterm: String,
		knownHostsUser: String,
		accessGroup: String?,
		hostsURL: URL,
		keychain: KeychainStore,
		controlMasterManager: ControlMasterTearDowning? = nil,
		preflight: PreflightProbing = Preflight(),
		configSink: SSHConfigSink = CatermSSHConfigSink(),
		managedKeyStore: ManagedKeyStore,
		credentialMaterialStore: SessionCredentialMaterialStore?,
		historyRecorder: SessionHistoryRecording? = nil
	) {
        self.askpassPath = askpassPath
        self.knownHostsCaterm = knownHostsCaterm
        self.knownHostsUser = knownHostsUser
        self.accessGroup = accessGroup
        self.hostsURL = hostsURL
        self.keychain = keychain
		self.managedKeyStore = managedKeyStore
		self.hostDeletionOutbox = HostDeletionOutbox(hostsURL: hostsURL)
		if let credentialMaterialStore {
			precondition(
				credentialMaterialStore.managedKeyStore === managedKeyStore,
				"SessionStore requires one canonical ManagedKeyStore"
			)
			self.credentialMaterialStore = credentialMaterialStore
		} else {
			self.credentialMaterialStore = SessionCredentialMaterialStore(
				keychainService: keychain.service,
				keychainAccessGroup: keychain.accessGroup,
				managedKeyStore: managedKeyStore
			)
		}
        self.controlMasterManager = controlMasterManager
        self.preflight = preflight
        self.configSink = configSink
		self.historyRecorder = historyRecorder
        do {
            self.hosts = try HostPersistence.load(from: hostsURL)
        } catch {
            self.hosts = []
        }
    }

    // MARK: - Host CRUD

    public func addHost(_ host: SSHHost) throws {
        var updated = hosts
        updated.append(host)
        try HostPersistence.save(updated, to: hostsURL)
        hosts = updated
        mutationsForSyncSubject.send()
    }

    public func updateHost(_ host: SSHHost) throws {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        var updated = host
		updated.credential = hosts[idx].credential
		updated.credentialMaterialDirty = hosts[idx].credentialMaterialDirty
        updated.updatedAt = Date()
        hosts[idx] = updated
        try HostPersistence.save(hosts, to: hostsURL)
        mutationsForSyncSubject.send()
    }

    /// Persists a user-driven batch as one atomic hosts.json replacement and
    /// emits one sync mutation. Device-local credential state is preserved.
    public func updateHosts(_ updatedHosts: [SSHHost]) throws {
        guard !updatedHosts.isEmpty else { return }
        var updatesByID: [UUID: SSHHost] = [:]
        for host in updatedHosts {
            updatesByID[host.id] = host
        }

        let timestamp = Date()
        var didUpdate = false
        var next = hosts
        for index in next.indices {
            guard var updated = updatesByID[next[index].id] else { continue }
            updated.credential = next[index].credential
            updated.credentialMaterialDirty = next[index].credentialMaterialDirty
            updated.updatedAt = timestamp
            next[index] = updated
            didUpdate = true
        }
        guard didUpdate else { return }

        try HostPersistence.save(next, to: hostsURL)
        hosts = next
        mutationsForSyncSubject.send()
    }

    public func pendingRemoteHostDeletionIDs() throws -> [String] {
        try hostDeletionOutbox.pendingIDs()
    }

    public func clearPendingRemoteHostDeletion(serverID: String) throws {
        try hostDeletionOutbox.remove(serverID)
    }

	public func recordPendingRemoteHostDeletion(serverID: String) throws {
		_ = try hostDeletionOutbox.insert(serverID)
	}

    public func deleteHost(id: UUID) async throws {
        try await deleteHost(id: id, enqueueRemoteDeletion: true)
    }

    public func applyRemoteHostDeletion(id: UUID) async throws {
        try await deleteHost(id: id, enqueueRemoteDeletion: false)
    }

    private func deleteHost(
        id: UUID,
        enqueueRemoteDeletion: Bool
    ) async throws {
        guard let host = hosts.first(where: { $0.id == id }) else { return }
        let serverID = enqueueRemoteDeletion ? host.serverId : nil
        let commit = try await credentialMaterialStore.beginDeletion(for: id)
        var insertedDeletionIntent = false
        if let serverID {
            do {
                insertedDeletionIntent = try hostDeletionOutbox.insert(serverID)
            } catch {
                let outboxError = error
                do {
                    try await credentialMaterialStore.rollbackDeletion(commit)
                } catch {
                    let rollbackDescription = String(describing: error)
                    Self.log.error(
                        "credential deletion rollback failed: \(id, privacy: .public): \(rollbackDescription, privacy: .public)"
                    )
                }
                throw outboxError
            }
        }
        var updated = hosts
        updated.removeAll { $0.id == id }
        do {
            try HostPersistence.save(updated, to: hostsURL)
        } catch {
            let persistenceError = error
            if insertedDeletionIntent, let serverID {
                do {
                    try hostDeletionOutbox.remove(serverID)
                } catch {
                    let rollbackDescription = String(describing: error)
                    Self.log.error(
                        "host deletion outbox rollback failed: \(serverID, privacy: .public): \(rollbackDescription, privacy: .public)"
                    )
                }
            }
            do {
                try await credentialMaterialStore.rollbackDeletion(commit)
            } catch {
                let rollbackDescription = String(describing: error)
                Self.log.error(
                    "credential deletion rollback failed: \(id, privacy: .public): \(rollbackDescription, privacy: .public)"
                )
            }
            throw persistenceError
        }
        hosts = updated
        await credentialMaterialStore.finalizeDeletion(commit)
        credentialAvailabilityRevision &+= 1
        if enqueueRemoteDeletion {
            mutationsForSyncSubject.send()
        }
    }

	/// Test seam for seeding Keychain-backed connection fixtures. Production
	/// credential writes must use `setHostCredentialMaterial`.
	func setHostSecret(_ secret: String, hostId: UUID, kind: SecretKind) throws {
		try keychain.set(
			account: SSHCredentialContract.account(
				hostID: hostId,
				kind: kind.credentialKind
			),
			secret: secret
		)
    }

    // MARK: - Tabs

    @discardableResult
    public func openTab(
		host: SSHHost,
		installTerminfo: Bool = false,
		authenticationMode: SSHAuthenticationMode = .configuredCredential
	) -> UUID {
		let historyEntryID = beginHistory(for: host)
        // 1. Resolve the jump-host chain. Fail-fast if broken or cyclic.
        let chainResolution = ChainResolver(hosts: hosts).resolve(host)
        guard chainResolution.isComplete else {
            let id = UUID()
            let msg = "Jump host chain is broken — edit host to fix"
			let failure = FailureKind.networkUnreachable(
				.other(code: 0, message: msg)
			)
            tabs.append(Tab(
				id: id,
				host: host,
				failedWith: failure,
				historyEntryID: historyEntryID
			))
			finishHistory(id: historyEntryID, outcome: .failed)
            return id
        }
        let chain = chainResolution.connectionOrder

        // 2. Register the tab, then let the async connection task validate
		// ancestor credentials through the credential-material lease.
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
        let id = UUID()
        tabs.append(Tab(id: id, host: host, resolvedChain: chain,
						installTerminfo: installTerminfo,
						authenticationMode: authenticationMode,
						historyEntryID: historyEntryID))
        startConnection(tabId: id)
        return id
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
		let historyOutcome: SessionHistoryOutcome = tabs[idx].hadConnected
			? .completed
			: .cancelled
		finishHistory(id: tabs[idx].historyEntryID, outcome: historyOutcome)
        // Cancel any in-flight startConnection probe for this tab so we don't
        // leak the underlying NWConnection while the user moves on.
        pendingStartTasks.removeValue(forKey: tabId)?.cancel()
		pendingReconnectTasks.removeValue(forKey: tabId)?.cancel()
		reconnectScheduleTokens.removeValue(forKey: tabId)
        connectionAttempts.removeValue(forKey: tabId)
		clearSkippedForwardNotices(forTab: tabId)
        // Clean up any per-session ssh_config written for a chained connection.
        if let configURL = tabs[idx].sshConfigURL {
            configSink.cleanup(configURL)
        }
        let hostId = tabs[idx].host.id
        // Capture the closed tab's host snapshot before removal so we can
        // inspect its `forwards` to decide between immediate teardown and
        // the grace-window path. The user's saved `hosts` array may not
        // contain this host (e.g. ad-hoc tabs in tests), so we trust the
        // tab's own copy.
        let closedHost = tabs[idx].host
        tabs.remove(at: idx)
        let stillReferenced = tabs.contains { $0.host.id == hostId }
        if !stillReferenced {
            // Differentiated teardown: hosts with port forwards leave
            // listening local sockets bound while the master is alive,
            // which is observable to the user (next bind attempt would
            // collide). Skip the grace and tear down immediately. Hosts
            // without forwards keep the grace so a quick reconnect can
            // reuse the warm master.
            let hostHadForwards = !closedHost.forwards.isEmpty
            if hostHadForwards, let manager = controlMasterManager {
                // Cancel any prior pending teardown for the same host so
                // the immediate path is authoritative.
                teardownWorkItems[hostId]?.cancel()
                teardownWorkItems.removeValue(forKey: hostId)
                Task { @MainActor in
                    await manager.tearDown(hostId: hostId)
                }
            } else {
                scheduleTeardown(hostId: hostId)
            }
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

    /// Build the command and environment from the tab's open-time snapshot.
    ///
    /// For chained (jump-host) connections the full `SSHCommandBuilder.Output`
    /// is captured in `tab.chainOutput` by `runConnection`. We return its
    /// (command, env) directly so the chain feature works end-to-end. The
    /// direct-path build is only invoked for single-hop (no-jump) tabs.
    public func surfaceConfig(
        for tabId: UUID,
        installTerminfo _: Bool = false
    ) -> (command: String, env: [(String, String)])? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        if let chainOut = tab.chainOutput {
            var env = chainOut.env
            if let accessGroup {
                env.append((SSHCredentialEnvironmentKey.accessGroup.rawValue, accessGroup))
            }
            return (chainOut.command, env)
        }
        let cmd = SSHCommandBuilder.build(
            host: tab.host,
            askpassPath: askpassPath,
            knownHostsCaterm: knownHostsCaterm,
            knownHostsUser: knownHostsUser,
			installTerminfo: tab.installTerminfo,
			authenticationMode: tab.authenticationMode
        )
        var env = cmd.env
        if let accessGroup {
            env.append((SSHCredentialEnvironmentKey.accessGroup.rawValue, accessGroup))
        }
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
		guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
		let host = tab.host
		let chain = tab.resolvedChain
		let token = (connectionAttempts[tabId] ?? 0) &+ 1
		connectionAttempts[tabId] = token

		for ancestor in chain {
			guard await needsCredentialSetup(ancestor) else { continue }
			applyIfCurrent(tabId: tabId, token: token) { current in
				let message = "\(ancestor.name) needs credentials configured first — connect to it directly to set them up"
				current.state = .failed(
					.networkUnreachable(.other(code: 0, message: message))
				)
			}
			if connectionAttempts[tabId] == token {
				pendingStartTasks.removeValue(forKey: tabId)
			}
			return
		}

		// Determine the first TCP hop address. Defense-in-depth: openTab already
		// validated the chain, but broken configurations can arise from race
		// conditions (host deleted while tab is open).
		guard let firstHop = host.firstHopAddress(in: hosts) else {
			applyIfCurrent(tabId: tabId, token: token) { t in
				let msg = "Jump host chain is broken — edit host to fix"
				t.state = .failed(.networkUnreachable(.other(code: 0, message: msg)))
			}
			if connectionAttempts[tabId] == token {
				pendingStartTasks.removeValue(forKey: tabId)
			}
			return
		}

		guard (1...65535).contains(firstHop.port) else {
			applyIfCurrent(tabId: tabId, token: token) { t in
				t.state = .failed(.networkUnreachable(.invalidPort(firstHop.port)))
			}
			if connectionAttempts[tabId] == token {
				pendingStartTasks.removeValue(forKey: tabId)
			}
			return
		}

		applyIfCurrent(tabId: tabId, token: token) { t in
			t.state = .preflight(startedAt: Date())
		}

		let outcome = await preflight.probe(
			host: firstHop.hostname,
			port: UInt16(firstHop.port),
			timeout: 5
		)

		// Handle TCP-preflight failure synchronously; bail out before probing
		// local binds. Success path falls through to forward preflight below.
		if case .failed(let reason) = outcome {
			applyIfCurrent(tabId: tabId, token: token) { t in
				t.state = .failed(.networkUnreachable(reason))
			}
			if connectionAttempts[tabId] == token {
				pendingStartTasks.removeValue(forKey: tabId)
			}
			return
		}

		// TCP preflight succeeded — now run the forward preflight before
		// spawning the ssh subprocess. Stale-attempt guard: a newer
		// startConnection may have run while we were awaiting probe; in that
		// case we must not clear or mutate @Published notice state on behalf
		// of a superseded attempt.
		guard connectionAttempts[tabId] == token else {
			pendingStartTasks.removeValue(forKey: tabId)
			return
		}
		// Clear any stale notices from a prior attempt before re-populating.
		clearSkippedForwardNotices(forTab: tabId)
		if let failure = await probeForwards(host.forwards, host: host,
		                                     tabId: tabId, token: token) {
			applyIfCurrent(tabId: tabId, token: token) { t in
				t.state = .failed(failure)
			}
			if connectionAttempts[tabId] == token {
				pendingStartTasks.removeValue(forKey: tabId)
			}
			return
		}

		applyIfCurrent(tabId: tabId, token: token) { t in
			// Capture the full chain Output from SSHCommandBuilder before
			// transitioning to .authenticating so surfaceConfig callers see it.
			if !chain.isEmpty {
				do {
					let output = try SSHCommandBuilder.build(
						host: host,
						ancestors: chain,
						configSink: self.configSink,
						askpassPath: self.askpassPath,
						knownHostsCaterm: self.knownHostsCaterm,
						knownHostsUser: self.knownHostsUser,
						installTerminfo: t.installTerminfo
					)
					t.chainOutput = output
					t.sshConfigURL = output.configURL
				} catch {
					let msg = "Failed to build chain SSH config: \(error)"
					t.state = .failed(.networkUnreachable(.other(code: 0, message: msg)))
					return
				}
			}
			t.surfaceGeneration += 1
			t.state = .authenticating(startedAt: Date())
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

	/// Returns `nil` on success. Returns a `FailureKind` to abort the
	/// connection with on the first **required** forward whose local bind
	/// fails. Optional forwards that fail are appended to
	/// `skippedForwardNotices` and do not abort. Remote forwards
	/// (`.remote`) are skipped — they bind on the server, not locally.
	///
	/// `tabId`/`token` are used to guard against stale-attempt mutation of
	/// `@Published` state. Each `await probeLocalBind` is a suspension point
	/// after which a newer `startConnection` may have bumped the attempt
	/// token; in that case we return `nil` without mutating notices or
	/// reporting a failure for a superseded attempt.
	private func probeForwards(_ forwards: [PortForward],
	                           host: SSHHost,
	                           tabId: UUID,
	                           token: UInt64) async -> FailureKind? {
		for forward in forwards where forward.kind != .remote {
			let addr = forward.bindAddress ?? "127.0.0.1"
			guard let nwPort = UInt16(exactly: forward.bindPort) else { continue }
			let outcome = await preflight.probeLocalBind(address: addr, port: nwPort)
			guard case .unavailable(let reason) = outcome else { continue }
			// Stale-attempt guard: don't mutate published state (notices) or
			// report a failure for a superseded run.
			guard connectionAttempts[tabId] == token else { return nil }
			if forward.required {
				return .portForwardBindFailed(forward: forward, reason: reason)
			} else {
				skippedForwardNotices.append(
					SkippedForwardNotice(tabId: tabId, hostId: host.id,
					                     forward: forward, reason: reason)
				)
			}
		}
		return nil
	}

	public func retryTab(tabId: UUID) {
		cancelScheduledReconnect(tabId: tabId)
		// Clean any ssh_config written by the previous attempt before starting
		// a fresh connection. Without this the old URL would be leaked when
		// `startConnection` overwrites `sshConfigURL` with a new value.
		guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
		let previous = tabs[idx]
		let previousOutcome: SessionHistoryOutcome = previous.hadConnected
			? .completed
			: .cancelled
		finishHistory(id: previous.historyEntryID, outcome: previousOutcome)
		let historyEntryID = beginHistory(for: previous.host)
		if let oldURL = previous.sshConfigURL {
			configSink.cleanup(oldURL)
			tabs[idx].sshConfigURL = nil
			tabs[idx].chainOutput = nil
		}
		update(tabId) {
			$0.lastFailure = nil
			$0.state = .idle
			$0.hadConnected = false
			$0.historyEntryID = historyEntryID
		}
		startConnection(tabId: tabId)
	}

	public func stopReconnect(tabId: UUID) {
		guard let tab = tabs.first(where: { $0.id == tabId }),
		      case .reconnecting = tab.state else {
			return
		}
		cancelScheduledReconnect(tabId: tabId)
		update(tabId) { current in
			current.lastFailure = .connectionDropped
			current.state = .failed(.connectionDropped)
		}
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

    /// Provisionally enter `.connected` to dismiss the connecting overlay early
    /// — without committing `hadConnected`. Used by the short-grace path when a
    /// silent remote shell (no OSC title/pwd) leaves us no positive "live"
    /// signal: the ssh process being alive this far past a successful TCP
    /// preflight is a strong hint it's connected, so we stop showing a spinner
    /// over what is almost always a working terminal. Because `hadConnected`
    /// stays `false`, a *slow* auth/setup failure that exits before the later
    /// `markConnected` confirm still classifies as `.authOrSetupFail` (not a
    /// reconnectable `.connectionDropped`). No-op if the tab already truly
    /// connected (e.g. the fast-path `onSessionLive` beat us here).
    public func markConnectedProvisional(tabId: UUID) {
        update(tabId) { tab in
            guard !tab.hadConnected else { return }
            if case .connected = tab.state { return }
            tab.state = .connected(connectedAt: Date())
        }
    }

    public func markChildExited(tabId: UUID, exitCode: Int32) {
		cancelScheduledReconnect(tabId: tabId)
        // Clean up any per-session ssh_config before state transition.
        if let idx = tabs.firstIndex(where: { $0.id == tabId }),
           let configURL = tabs[idx].sshConfigURL {
            configSink.cleanup(configURL)
            tabs[idx].sshConfigURL = nil
            tabs[idx].chainOutput = nil
        }
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
		let token = (reconnectScheduleTokens[tabId] ?? 0) &+ 1
		reconnectScheduleTokens[tabId] = token
		pendingReconnectTasks.removeValue(forKey: tabId)?.cancel()
		let task = Task { @MainActor [weak self] in
			do {
				try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
			} catch {
				return
			}
			guard let self,
			      self.reconnectScheduleTokens[tabId] == token,
			      let tab = self.tabs.first(where: { $0.id == tabId }),
			      case .reconnecting = tab.state else { return }
			self.pendingReconnectTasks.removeValue(forKey: tabId)
			self.reconnectScheduleTokens.removeValue(forKey: tabId)
			// Keep the previous terminal surface until preflight succeeds. The
			// success path bumps surfaceGeneration immediately before starting
			// the replacement SSH process, so a failed probe preserves output.
			// Route through startConnection so the reconnect attempt also gets
            // TCP preflight + typed networkUnreachable failure if the network
            // is still down.
			self.startConnection(tabId: tabId)
		}
		pendingReconnectTasks[tabId] = task
    }

	private func cancelScheduledReconnect(tabId: UUID) {
		pendingReconnectTasks.removeValue(forKey: tabId)?.cancel()
		reconnectScheduleTokens.removeValue(forKey: tabId)
	}

    private func update(_ tabId: UUID, _ mutate: (inout Tab) -> Void) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
		let previous = tabs[idx]
		var tab = previous
        mutate(&tab)
        tabs[idx] = tab
		if !previous.hadConnected, tab.hadConnected {
			markHistoryConnected(id: tab.historyEntryID)
		}
		if case let .failed(failure) = tab.state {
			if case .failed = previous.state {
				return
			}
			let outcome: SessionHistoryOutcome = failure == .cleanExit
				? .completed
				: .failed
			finishHistory(id: tab.historyEntryID, outcome: outcome)
		}
    }

	private func beginHistory(for host: SSHHost) -> UUID? {
		guard let historyRecorder else { return nil }
		let isSavedHost = hosts.contains(where: { $0.id == host.id })
		do {
			return try historyRecorder.begin(
				host: SessionHistoryHost(
					savedHostID: isSavedHost ? host.id : nil,
					displayName: host.name,
					hostname: host.hostname,
					port: host.port,
					username: host.username
				),
				connectionKind: isSavedHost ? .savedHost : .oneTime,
				at: Date()
			)
		} catch {
			Self.log.error("failed to begin session history: \(String(describing: error), privacy: .public)")
			return nil
		}
	}

	private func markHistoryConnected(id: UUID?) {
		guard let id, let historyRecorder else { return }
		do {
			try historyRecorder.markConnected(id: id, at: Date())
		} catch {
			Self.log.error("failed to update session history: \(String(describing: error), privacy: .public)")
		}
	}

	private func finishHistory(
		id: UUID?,
		outcome: SessionHistoryOutcome
	) {
		guard let id, let historyRecorder else { return }
		do {
			try historyRecorder.finish(id: id, outcome: outcome, at: Date())
		} catch {
			Self.log.error("failed to finish session history: \(String(describing: error), privacy: .public)")
		}
	}

    // MARK: - Sync support (v1.1)

    /// True when this host has no usable local credential. Pulled hosts always
    /// fall here (no Keychain item under their local UUID). Local-only `.agent`
    /// hosts are always false. See spec §7.1.2 needsCredentialSetup.
	public func needsCredentialSetup(
		_ host: SSHHost,
		interaction: KeychainReadInteraction = .userInitiated
	) async -> Bool {
		var source = hosts.first(where: { $0.id == host.id })?.credential
			?? host.credential
		while true {
			guard let check = await credentialMaterialStore
				.beginCredentialSetupCheck(
					for: host.id,
					source: source,
					interaction: interaction
				) else {
				return true
			}
			guard let currentSource = hosts.first(where: {
				$0.id == host.id
			})?.credential else {
				await credentialMaterialStore.finishCredentialSetupCheck(check)
				return true
			}
			if currentSource == source {
				await credentialMaterialStore.finishCredentialSetupCheck(check)
				return check.requiresSetup
			}
			await credentialMaterialStore.finishCredentialSetupCheck(check)
			source = currentSource
		}
    }

	public func managedKeyPath(for hostId: UUID) -> String {
		managedKeyStore.path(hostId: hostId).path
	}

    /// Replace the `serverId` of an existing host in-memory and persist.
    public func setServerId(_ serverId: String, for hostId: UUID) throws {
        guard let updated = HostRepositoryProjection.assigning(
            serverID: serverId,
            to: hostId,
            in: hosts
        ) else { throw HostSynchronizationError.localHostMissing(hostId) }
        try HostPersistence.save(updated, to: hostsURL)
        hosts = updated
    }

    /// Replaces synced metadata without touching credential or serverId. Used
    /// when a remote update lands.
    public func applyRemoteMetadata(localHostId: UUID, remote: RemoteHost) throws {
        guard let updated = HostRepositoryProjection.applying(
            remote,
            to: localHostId,
            in: hosts
        ) else { throw HostSynchronizationError.localHostMissing(localHostId) }
        try HostPersistence.save(updated, to: hostsURL)
        hosts = updated
    }

    /// Insert a host fetched from the server. Allocates a fresh local UUID,
    /// stamps `serverId` from `remote.id`, defaults credential to `.password`
    /// (so first connect prompts the user — see needsCredentialSetup).
    @discardableResult
    public func addRemoteHost(_ remote: RemoteHost) throws -> UUID {
        let result = HostRepositoryProjection.inserting(remote, into: hosts)
        try HostPersistence.save(result.hosts, to: hostsURL)
        hosts = result.hosts
        return result.localID
    }

    /// Replace the credential overlay for an existing host. Does NOT bump
    /// `updatedAt` — credential is a device-local concept that never propagates
    /// to the server, so it must not trigger reconciler `.updateRemote` ops.
    ///
    /// Atomicity: persists to a local copy first; only assigns to `self.hosts`
    /// after `HostPersistence.save` returns. A disk-write failure throws
    /// without mutating in-memory state, so callers can treat the call as
    /// all-or-nothing for SessionStore-side state.
	func setCredentialOnly(_ source: CredentialSource,
	                       for hostId: UUID) throws {
        guard let idx = hosts.firstIndex(where: { $0.id == hostId }) else { return }
        var updated = hosts
        updated[idx].credential = source
        try HostPersistence.save(updated, to: hostsURL)
        hosts = updated
    }

	/// Single local credential-material mutation entry point. The material store
	/// retains a per-host transaction lease until the credential source, dirty
	/// bit, and notification have committed on the main actor.
	public func setHostCredentialMaterial(
		secrets: HostSecrets,
		credentialSource: CredentialSource,
		for hostId: UUID
	) async throws {
		guard hosts.contains(where: { $0.id == hostId }) else { return }
		let localSource: LocalCredentialSource
		switch credentialSource {
		case .password:
			localSource = .password
		case let .keyFile(path, hasPassphrase):
			localSource = .keyFile(
				path: path,
				hasPassphrase: hasPassphrase
			)
		case .agent:
			localSource = .agent
		}

		let commit = try await credentialMaterialStore.applyLocal(
			secrets,
			source: localSource,
			for: hostId
		)
		do {
			try Task.checkCancellation()
		} catch {
			if hosts.contains(where: { $0.id == hostId }) {
				try await credentialMaterialStore.rollbackLocalCommit(commit)
			} else {
				try await credentialMaterialStore
					.discardLocalCommitForDeletedHost(commit)
			}
			throw error
		}

		guard let idx = hosts.firstIndex(where: { $0.id == hostId }) else {
			try await credentialMaterialStore
				.discardLocalCommitForDeletedHost(commit)
			return
		}
		let resolvedSource: CredentialSource
		switch commit.source {
		case .password:
			resolvedSource = .password
		case let .keyFile(path, hasPassphrase):
			resolvedSource = .keyFile(
				keyPath: path,
				hasPassphrase: hasPassphrase
			)
		case .agent:
			resolvedSource = .agent
		}
		var updated = hosts
		updated[idx].credential = resolvedSource
		updated[idx].credentialMaterialDirty = true
		do {
			try HostPersistence.save(updated, to: hostsURL)
		} catch {
			let persistenceError = error
			try await credentialMaterialStore.rollbackLocalCommit(commit)
			throw persistenceError
		}
		hosts = updated

		NotificationCenter.default.post(
			name: .catermHostCredentialMaterialChanged,
			object: nil,
			userInfo: [CatermHostCredentialMaterialChangedKeys.hostId: hostId]
		)
		await credentialMaterialStore.finalizeLocalCommit(commit)
		credentialAvailabilityRevision &+= 1
	}

	/// Relocates a legacy external key reference into the canonical managed
	/// store without creating a sync-visible credential edit.
	public func migrateExternalPrivateKey(
		_ privateKeyBytes: Data,
		from expectedSource: CredentialSource,
		for hostId: UUID
	) async throws -> Bool {
		guard case let .keyFile(_, hasPassphrase) = expectedSource,
		      hosts.first(where: { $0.id == hostId })?.credential == expectedSource else {
			return false
		}

		let expectedGeneration = await credentialMaterialStore.currentGeneration(
			for: hostId
		)
		guard hosts.first(where: { $0.id == hostId })?.credential == expectedSource,
		      let commit = try await credentialMaterialStore.applyMigration(
				privateKeyBytes: privateKeyBytes,
				for: hostId,
				expectedGeneration: expectedGeneration
		      ) else {
			return false
		}

		do {
			try Task.checkCancellation()
		} catch {
			if hosts.contains(where: { $0.id == hostId }) {
				try await credentialMaterialStore.rollbackMigration(commit)
			} else {
				try await credentialMaterialStore
					.discardMigrationForDeletedHost(commit)
			}
			throw error
		}

		guard let index = hosts.firstIndex(where: { $0.id == hostId }) else {
			try await credentialMaterialStore.discardMigrationForDeletedHost(commit)
			return false
		}
		guard hosts[index].credential == expectedSource else {
			try await credentialMaterialStore.rollbackMigration(commit)
			return false
		}

		var updated = hosts
		updated[index].credential = .keyFile(
			keyPath: commit.managedPath,
			hasPassphrase: hasPassphrase
		)
		do {
			try HostPersistence.save(updated, to: hostsURL)
		} catch {
			let persistenceError = error
			do {
				try await credentialMaterialStore.rollbackMigration(commit)
			} catch {
				let rollbackDescription = String(describing: error)
				Self.log.error(
					"credential migration rollback failed: \(hostId, privacy: .public): \(rollbackDescription, privacy: .public)"
				)
			}
			throw persistenceError
		}
		hosts = updated
		await credentialMaterialStore.finalizeMigration(commit)
		credentialAvailabilityRevision &+= 1
		return true
	}

	public func resetCredentialMaterialForAccountChange() async throws {
		try await credentialMaterialStore.resetAllCredentialMaterialForAccountChange(
			hostIDs: hosts.map(\.id)
		)
		credentialAvailabilityRevision &+= 1
	}

	public func clearCredentialMaterialDirty(_ hostId: UUID) throws {
		guard let idx = hosts.firstIndex(where: { $0.id == hostId }) else { return }
		guard hosts[idx].credentialMaterialDirty else { return }  // idempotent
		var updated = hosts
		updated[idx].credentialMaterialDirty = false
		try HostPersistence.save(updated, to: hostsURL)
		hosts = updated
	}

	/// Commits the resulting credential reference to main-actor host state after
	/// a background worker has persisted the credential bytes. Remote material
	/// never sets the local dirty bit, which avoids a redundant push loop.
	public func applyRemoteCredentialSource(
		_ commit: RemoteCredentialMaterialCommit
	) async throws {
		let hostId = commit.hostId
		guard let idx = hosts.firstIndex(where: { $0.id == hostId }) else { return }
		var updated = hosts
		switch commit.source {
		case .unchanged:
			break
		case .password:
			updated[idx].credential = .password
		case let .keyFile(path, hasPassphrase):
			updated[idx].credential = .keyFile(
				keyPath: path,
				hasPassphrase: hasPassphrase
			)
		}
		try HostPersistence.save(updated, to: hostsURL)
		hosts = updated
		credentialAvailabilityRevision &+= 1
	}

	// MARK: - Test helpers (internal — accessible via @testable import)

	/// Inject a `sshConfigURL` onto a tab without going through the async
	/// connection flow. Used by tests that want to verify `closeTab` cleanup.
	internal func setSSHConfigURLForTest(_ url: URL, tabId: UUID) {
		guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
		tabs[idx].sshConfigURL = url
	}

	/// Synthesise a chain build and store the full `Output` on the tab,
	/// simulating what `runConnection` does after a successful preflight probe.
	/// Used by tests that need `surfaceConfig` to return a chain-aware result
	/// without running the async connection flow.
	///
	/// Pass `installTerminfo: true` to exercise the terminfo-wrapping path
	/// (I-1 regression: chain build must respect this flag).
	internal func populateChainOutputForTest(tabId: UUID, installTerminfo: Bool = false) {
		guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
		do {
			let output = try SSHCommandBuilder.build(
				host: tabs[idx].host,
				ancestors: tabs[idx].resolvedChain,
				configSink: configSink,
				askpassPath: askpassPath,
				knownHostsCaterm: knownHostsCaterm,
				knownHostsUser: knownHostsUser,
				installTerminfo: installTerminfo
			)
			tabs[idx].chainOutput = output
			tabs[idx].sshConfigURL = output.configURL
		} catch {
			// Test setup error — surface it so the calling test can diagnose it.
			print("populateChainOutputForTest failed: \(error)")
		}
	}

	/// Construct a `SessionStore` suitable for unit tests.
	///
	/// - `hosts`: Pre-populated host list; injected directly so no disk I/O
	///   is needed.
	/// - `credentialsAvailableFor`: Set of host `id`s for which
	///   `needsCredentialSetup` should return `false`. The factory writes a
	///   dummy password to the isolated test keychain for each listed id so the
	///   leased credential-availability read observes committed material.
	/// - `configSink`: Injected `SSHConfigSink`; defaults to
	///   `InMemorySSHConfigSink` so tests never touch the filesystem.
	public static func makeForTest(
		hosts: [SSHHost] = [],
		credentialsAvailableFor: Set<UUID> = [],
		configSink: SSHConfigSink = InMemorySSHConfigSink()
	) -> SessionStore {
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-chain-test-\(UUID().uuidString).json")
		let kc = KeychainStore(service: "com.caterm.test.\(UUID().uuidString)",
		                       accessGroup: nil)
		// Write a dummy password for each host that should appear credentialed.
		for hostId in credentialsAvailableFor {
			try? kc.set(
				account: SSHCredentialContract.account(
					hostID: hostId, kind: .password),
				secret: "dummy"
			)
		}
		let store = SessionStore(
			askpassPath: "/dev/null",
			knownHostsCaterm: "/dev/null",
			knownHostsUser: "/dev/null",
			accessGroup: nil,
			hostsURL: tmp,
			keychain: kc,
			configSink: configSink
		)
		// Inject hosts directly — bypasses disk persistence and
		// avoids HostPersistence.save touching tmp.
		store.hosts = hosts
		return store
	}
}
