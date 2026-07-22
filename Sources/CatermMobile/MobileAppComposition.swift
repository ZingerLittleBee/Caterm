import CatermMobileTerminal
import CloudKit
import CloudKitSyncClient
import CredentialSync
import CredentialSyncStore
import Foundation
import KeychainStore
import ManagedKeyStore
import ServerSyncClient
import SessionStore
import SSHCommandBuilder
import SSHCredentialContract

@MainActor
public final class MobileAppComposition: ObservableObject {
	public let hostStore: MobileHostStore
	public let credentialWriter: MobileCredentialWriter
	public let syncRuntime: MobileHostSyncRuntime
	public let terminalSessionFactory: MobileTerminalSessionFactory
	public let prepareCredentialSyncForSave: () async throws -> Void
	public let startObservingAccountChanges: () -> Void

	public init(
		hostStore: MobileHostStore,
		credentialWriter: MobileCredentialWriter,
		syncRuntime: MobileHostSyncRuntime,
		terminalSessionFactory: MobileTerminalSessionFactory,
		prepareCredentialSyncForSave: @escaping () async throws -> Void = {},
		startObservingAccountChanges: @escaping () -> Void = {}
	) {
		self.hostStore = hostStore
		self.credentialWriter = credentialWriter
		self.syncRuntime = syncRuntime
		self.terminalSessionFactory = terminalSessionFactory
		self.prepareCredentialSyncForSave = prepareCredentialSyncForSave
		self.startObservingAccountChanges = startObservingAccountChanges
	}

	public static func live(
		hostsURL: URL,
		applicationSupportURL: URL,
		credentialDefaults: UserDefaults = .standard,
		masterKeyStore: KeychainSyncMasterKeyStore = KeychainSyncMasterKeyStore(),
		cloudKitEnabled: Bool = Bundle.main.object(
			forInfoDictionaryKey: "CatermCloudKitEnabled"
		) as? Bool ?? false,
		containerFactory: () -> CKContainer = {
			CKContainer(identifier: "iCloud.com.caterm.app")
		}
	) -> MobileAppComposition {
		let managedKeyStore = ManagedKeyStore(
			rootURL: applicationSupportURL.appendingPathComponent(
				"keys", isDirectory: true
			)
		)
		let materialStore = SessionCredentialMaterialStore(
			keychainService: SSHCredentialContract.keychainService,
			keychainAccessGroup: nil,
			managedKeyStore: managedKeyStore
		)
		let credentialWriter = MobileCredentialWriter(
			keychain: KeychainStore(
				service: SSHCredentialContract.keychainService,
				accessGroup: nil
			)
		)
		let hostStore = MobileHostStore(
			fileURL: hostsURL,
			credentialWriter: credentialWriter,
			managedKeyStore: managedKeyStore,
			credentialMaterialStore: materialStore
		)
		#if targetEnvironment(simulator)
		seedSimulatorCachedHostIfRequested(in: hostStore)
		#endif
		let credentialSync = CredentialSyncPreferencesStore(
			defaults: credentialDefaults
		)
		if case .disabled = credentialSync.prefs.state {
			credentialSync.mutate {
				$0.state = .enabled
				$0.credentialsNeedFullScan = true
			}
		}
		let credentialSyncCoordinator = CredentialSyncCoordinator(
			prefsStore: credentialSync,
			masterKeyStore: masterKeyStore
		)
		let planProvider = MobileAuthenticationPlanProvider(
			materialStore: materialStore
		)
		let terminalFactory = makeTerminalFactory(
			planProvider: planProvider,
			credentialSync: credentialSync,
			knownHostsURL: applicationSupportURL.appendingPathComponent(
				"known_hosts.json"
			)
		)

		#if targetEnvironment(simulator)
		if let client = simulatorBoundaryClientIfRequested() {
			let syncEngine = SharedHostSyncEngine(
				client: client,
				repository: hostStore,
				credentialSync: credentialSync,
				masterKeyStore: masterKeyStore,
				materialStore: materialStore
			)
			let runtime = MobileHostSyncRuntime(
				hostStore: hostStore,
				syncEngine: syncEngine,
				client: client,
				credentialSync: credentialSync,
				isSignedIn: { true },
				refreshAccount: {}
			)
			return MobileAppComposition(
				hostStore: hostStore,
				credentialWriter: credentialWriter,
				syncRuntime: runtime,
				terminalSessionFactory: terminalFactory,
				prepareCredentialSyncForSave: {
					try await credentialSyncCoordinator.enable()
				}
			)
		}
		#endif

		guard cloudKitEnabled else {
			let client = OfflineMobileHostSyncClient()
			let syncEngine = SharedHostSyncEngine(
				client: client,
				repository: hostStore,
				credentialSync: credentialSync,
				masterKeyStore: masterKeyStore,
				materialStore: materialStore
			)
			let runtime = MobileHostSyncRuntime(
				hostStore: hostStore,
				syncEngine: syncEngine,
				client: client,
				credentialSync: credentialSync,
				isSignedIn: { false },
				refreshAccount: {}
			)
			return MobileAppComposition(
				hostStore: hostStore,
				credentialWriter: credentialWriter,
				syncRuntime: runtime,
				terminalSessionFactory: terminalFactory,
				prepareCredentialSyncForSave: {
					try await credentialSyncCoordinator.enable()
				}
			)
		}

		let container = containerFactory()
		let client = CloudKitSyncClient(database: container.privateCloudDatabase)
		let accountSession = iCloudAccountSession(provider: container)
		let syncEngine = SharedHostSyncEngine(
			client: client,
			repository: hostStore,
			credentialSync: credentialSync,
			masterKeyStore: masterKeyStore,
			materialStore: materialStore
		)
		let identityTracker = AccountIdentityTracker(
			currentIdentity: {
				await CloudKitAccountIdentityObserver.observe(provider: container)
			},
			tokensExist: {
				if await client.hasAnyHostSyncTokens() { return true }
				return await hostStore.hasIdentityBoundState()
			}
		)
		let identityBoundary = MobileAccountIdentityBoundary(
			evaluate: {
				await identityTracker.handleAccountChange(client: client)
			},
			acknowledge: {
				await identityTracker.acknowledgeIdentityChange()
			}
		)
		let runtime = MobileHostSyncRuntime(
			hostStore: hostStore,
			syncEngine: syncEngine,
			client: client,
			credentialSync: credentialSync,
			isSignedIn: { accountSession.isSignedIn },
			refreshAccount: { await accountSession.refresh() },
			identityBoundary: identityBoundary
		)

		return MobileAppComposition(
			hostStore: hostStore,
			credentialWriter: credentialWriter,
			syncRuntime: runtime,
			terminalSessionFactory: terminalFactory,
			prepareCredentialSyncForSave: {
				try await credentialSyncCoordinator.enable()
			},
			startObservingAccountChanges: {
				accountSession.startObservingAccountChanges()
			}
		)
	}

	private static func makeTerminalFactory(
		planProvider: MobileAuthenticationPlanProvider,
		credentialSync: CredentialSyncPreferencesStore,
		knownHostsURL: URL
	) -> MobileTerminalSessionFactory {
		MobileTerminalSessionFactory { host in
			let result = await planProvider.resolve(
				host: host,
				credentialSyncState: credentialSync.prefs.state
			)
			let plan: SSHAuthPlan
			switch result {
			case let .available(value):
				plan = value
			case let .unavailable(reason):
				#if targetEnvironment(simulator)
				if let injected = simulatorPlan(host: host) {
					plan = injected
				} else {
					throw reason
				}
				#else
				throw reason
				#endif
			}
			let knownHosts = MobileKnownHostsStore(fileURL: knownHostsURL)
			let transport = NIOSSHTransport(
				host: host,
				plan: plan,
				knownHosts: knownHosts
			)
			return SSHTerminalSession(host: host, transport: transport)
		}
	}

	#if targetEnvironment(simulator)
	private static func simulatorBoundaryClientIfRequested()
		-> SimulatorHostSyncBoundaryClient? {
		#if DEBUG
		let environment = ProcessInfo.processInfo.environment
		guard let name = environment["CATERM_SIM_SYNC_REMOTE_HOST_NAME"],
			!name.isEmpty else { return nil }
		return SimulatorHostSyncBoundaryClient(remote: RemoteHost(
			id: "simulator-boundary-host",
			name: name,
			hostname: environment["CATERM_SIM_SYNC_REMOTE_HOST_ADDRESS"]
				?? "fixture.example.com",
			port: 22,
			username: environment["CATERM_SIM_SYNC_REMOTE_HOST_USER"]
				?? "fixture",
			authType: "agent",
			createdAt: Date(timeIntervalSince1970: 1_700_000_000),
			updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
			organization: HostOrganization(tags: ["deterministic-fixture"])
		))
		#else
		return nil
		#endif
	}

	private static func seedSimulatorCachedHostIfRequested(
		in store: MobileHostStore
	) {
		#if DEBUG
		let environment = ProcessInfo.processInfo.environment
		guard store.hosts.isEmpty,
			let name = environment["CATERM_SIM_CACHED_HOST_NAME"],
			!name.isEmpty else { return }
		let host = SSHHost(
				name: name,
				hostname: environment["CATERM_SIM_CACHED_HOST_ADDRESS"]
					?? "offline.example.com",
				username: environment["CATERM_SIM_CACHED_HOST_USER"]
					?? "offline",
				credential: .agent,
				organization: HostOrganization(tags: ["offline"])
			)
		Task { @MainActor in
			try? await store.add(host)
		}
		#endif
	}

	private static func simulatorPlan(host: SSHHost) -> SSHAuthPlan? {
		let environment = ProcessInfo.processInfo.environment
		let password = environment["CATERM_SIM_SSH_PASSWORD"]
		let passphrase = environment["CATERM_SIM_SSH_PASSPHRASE"]
		let keyBlob: Data? = {
			guard case let .keyFile(path, _) = host.credential else { return nil }
			return FileManager.default.contents(
				atPath: (path as NSString).expandingTildeInPath
			)
		}()
		let plan = SSHAuthPlan.make(
			host: host,
			password: password,
			keyBlob: keyBlob,
			passphrase: passphrase
		)
		return plan.missing == nil ? plan : nil
	}
	#endif
}

#if targetEnvironment(simulator)
private actor SimulatorHostSyncBoundaryClient: IncrementalHostSyncClient {
	private var hosts: [String: RemoteHost]
	private var nextID = 0

	init(remote: RemoteHost) {
		hosts = [remote.id: remote]
	}

	func listHosts() async throws -> [RemoteHost] { Array(hosts.values) }

	func createHost(_ input: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput {
		nextID += 1
		let id = "simulator-local-\(nextID)"
		hosts[id] = RemoteHost(
			id: id,
			name: input.name,
			hostname: input.hostname,
			port: input.port,
			username: input.username,
			authType: input.authType,
			createdAt: input.metadataUpdatedAt,
			updatedAt: input.metadataUpdatedAt,
			jumpHostServerId: input.jumpHostServerId,
			forwards: input.forwards,
			icon: input.icon,
			organization: input.organization
		)
		return RemoteHostCreateOutput(id: id)
	}

	func updateHost(_ input: RemoteHostUpdateInput) async throws {
		guard let current = hosts[input.id] else { return }
		hosts[input.id] = RemoteHost(
			id: current.id,
			name: input.name ?? current.name,
			hostname: input.hostname ?? current.hostname,
			port: input.port ?? current.port,
			username: input.username ?? current.username,
			authType: input.authType ?? current.authType,
			createdAt: current.createdAt,
			updatedAt: input.metadataUpdatedAt ?? current.updatedAt,
			jumpHostServerId: input.jumpHostServerId,
			forwards: input.forwards ?? current.forwards,
			icon: input.icon,
			organization: input.organization ?? current.organization
		)
	}

	func deleteHost(id: String) async throws { hosts.removeValue(forKey: id) }
	func preferredHostSyncMode() async -> HostSyncMode { .forceFull }
	func fetchHostChanges() async throws -> HostChangeBatch {
		try await fetchHostSnapshotAndCheckpoint()
	}
	func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch {
		HostChangeBatch(
			changedHosts: Array(hosts.values),
			deletedHostIDs: [],
			checkpoint: nil,
			tokenExpired: false,
			mode: .forceFull
		)
	}
	func commitHostCheckpoint(_: any HostSyncCheckpoint) async throws {}
	func resetHostSyncState() async {}
	func ensureHostSubscription() async throws {}
	func deleteHostSubscription() async throws {}
}
#endif

private final class OfflineMobileHostSyncClient: IncrementalHostSyncClient,
	@unchecked Sendable {
	func listHosts() async throws -> [RemoteHost] { [] }

	func createHost(_: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput {
		throw ServerSyncError.notSignedIn
	}

	func updateHost(_: RemoteHostUpdateInput) async throws {
		throw ServerSyncError.notSignedIn
	}

	func deleteHost(id _: String) async throws {
		throw ServerSyncError.notSignedIn
	}

	func preferredHostSyncMode() async -> HostSyncMode { .forceFull }

	func fetchHostChanges() async throws -> HostChangeBatch {
		try await fetchHostSnapshotAndCheckpoint()
	}

	func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch {
		HostChangeBatch(
			changedHosts: [],
			deletedHostIDs: [],
			checkpoint: nil,
			tokenExpired: false,
			mode: .forceFull
		)
	}

	func commitHostCheckpoint(_: any HostSyncCheckpoint) async throws {}
	func resetHostSyncState() async {}
	func ensureHostSubscription() async throws {}
	func deleteHostSubscription() async throws {}
}
