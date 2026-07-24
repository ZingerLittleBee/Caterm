import CatermMobileTerminal
import CloudKit
import CloudKitSyncClient
import Combine
import CredentialIdentitySecurity
import CredentialIdentityStore
import CredentialIdentitySync
import CredentialSync
import CredentialSyncStore
import FileTransferStore
import Foundation
import KeychainStore
import ManagedKeyStore
import ServerSyncClient
import SessionStore
import SettingsStore
import SettingsSyncStore
import SnippetStore
import SnippetSyncClient
import SSHCommandBuilder
import SSHCredentialContract

@MainActor
public final class MobileAppComposition: ObservableObject {
	public let hostStore: MobileHostStore
	public let credentialWriter: MobileCredentialWriter
	public let syncRuntime: MobileHostSyncRuntime
	public let snippetStore: SnippetStore
	public let snippetSyncRuntime: MobileSnippetSyncRuntime
	public let settingsStore: SettingsStore
	public let syncCoordinator: MobileSyncCoordinator
	public let terminalSessionFactory: MobileTerminalSessionFactory
	public let remoteFileClientFactory: MobileRemoteFileClientFactory
	public let fileTransferStore: FileTransferStore
	public let transferWorkspace: MobileTransferWorkspace
	public let transferLifecycle: MobileTransferLifecycleCoordinator
	public let prepareCredentialSyncForSave: MobileCredentialSyncPreparation
	public let credentialIdentityStore: CredentialIdentityStore?
	public let credentialIdentityMaterialStore:
		CredentialIdentityMaterialStore?
	private var transferCancellables: Set<AnyCancellable> = []
	private var knownTransferHostIDs: Set<UUID>

	public init(
		hostStore: MobileHostStore,
		credentialWriter: MobileCredentialWriter,
		syncRuntime: MobileHostSyncRuntime,
		snippetStore: SnippetStore,
		snippetSyncRuntime: MobileSnippetSyncRuntime,
		settingsStore: SettingsStore,
		settingsSync: SettingsSyncStore?,
		cloudSyncAvailable: Bool = true,
		terminalSessionFactory: MobileTerminalSessionFactory,
		remoteFileClientFactory: MobileRemoteFileClientFactory = .unavailable,
		transferWorkspace: MobileTransferWorkspace? = nil,
		credentialIdentityStore: CredentialIdentityStore? = nil,
		credentialIdentityMaterialStore:
			CredentialIdentityMaterialStore? = nil,
		prepareCredentialSyncForSave: @escaping MobileCredentialSyncPreparation = { _ in },
		syncCredentialIdentities:
			@escaping @MainActor @Sendable () async throws -> Void = {},
		startObservingAccountChanges: @escaping () -> Void = {}
	) {
		self.hostStore = hostStore
		self.knownTransferHostIDs = Set(hostStore.hosts.map(\.id))
		self.credentialWriter = credentialWriter
		self.syncRuntime = syncRuntime
		self.snippetStore = snippetStore
		self.snippetSyncRuntime = snippetSyncRuntime
		self.settingsStore = settingsStore
		self.credentialIdentityStore = credentialIdentityStore
		self.credentialIdentityMaterialStore =
			credentialIdentityMaterialStore
		let syncCoordinator = MobileSyncCoordinator(
			hostRuntime: syncRuntime,
			snippetRuntime: snippetSyncRuntime,
			settingsSync: settingsSync,
			isAvailable: cloudSyncAvailable,
			relatedSync: syncCredentialIdentities,
			startObservingAccountChanges: startObservingAccountChanges
		)
		self.syncCoordinator = syncCoordinator
		self.terminalSessionFactory = terminalSessionFactory
		self.remoteFileClientFactory = remoteFileClientFactory
		let workspace = transferWorkspace ?? MobileTransferWorkspace(
			rootURL: FileManager.default.temporaryDirectory
				.appendingPathComponent("CatermTransfers", isDirectory: true)
		)
		self.transferWorkspace = workspace
		let cleanupTransferPayload: @Sendable (TransferTask) async -> Void = { task in
			guard task.kind == .upload else { return }
			do {
				try await workspace.removeUploadPayload(
					at: URL(fileURLWithPath: task.source)
				)
			} catch {
				NSLog("[MobileAppComposition] Upload cleanup failed: \(error)")
			}
		}
		let fileTransferStore = FileTransferStore(
			clientForHost: { host in
				MobileDeferredRemoteFileClient(
					host: host,
					factory: remoteFileClientFactory
				)
			},
			didComplete: cleanupTransferPayload,
			didDiscard: cleanupTransferPayload
		)
		self.fileTransferStore = fileTransferStore
		self.transferLifecycle = MobileTransferLifecycleCoordinator(
			store: fileTransferStore,
			becameActive: { await syncCoordinator.becameActive() }
		)
		self.prepareCredentialSyncForSave = prepareCredentialSyncForSave
		bindGlobalTransferEvents()
	}

	private func bindGlobalTransferEvents() {
		NotificationCenter.default.publisher(for: .catermICloudAccountChanged)
			.sink { [weak self] _ in
				guard let self else { return }
				Task { await self.syncCoordinator.accountChanged() }
			}
			.store(in: &transferCancellables)

		syncRuntime.$identityRevision
			.dropFirst()
			.sink { [weak self] _ in
				guard let self else { return }
				Task { await self.fileTransferStore.resetForAccountChange() }
			}
			.store(in: &transferCancellables)

		hostStore.$hosts
			.sink { [weak self] hosts in self?.hostsDidChange(hosts) }
			.store(in: &transferCancellables)
	}

	private func hostsDidChange(_ hosts: [SSHHost]) {
		let currentHostIDs = Set(hosts.map(\.id))
		for hostID in currentHostIDs.subtracting(knownTransferHostIDs) {
			fileTransferStore.restoreHost(hostID)
		}
		let removedHostIDs = knownTransferHostIDs.subtracting(currentHostIDs)
		knownTransferHostIDs = currentHostIDs
		for hostID in removedHostIDs {
			guard let removal = fileTransferStore.beginHostRemoval(hostID) else {
				continue
			}
			Task { [weak self] in
				guard let self,
					!self.knownTransferHostIDs.contains(hostID) else {
					return
				}
				await self.fileTransferStore.drainHostRemoval(removal)
				guard !self.knownTransferHostIDs.contains(hostID) else {
					self.fileTransferStore.abortHostRemoval(removal)
					return
				}
				await self.fileTransferStore.commitHostRemoval(removal)
			}
		}
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
		let snippetStore = SnippetStore(directory: applicationSupportURL)
		do {
			try snippetStore.load()
		} catch {
			NSLog("[MobileAppComposition] Snippet load failed: \(error)")
		}
		let settingsURL = applicationSupportURL.appendingPathComponent(
			"settings.plist"
		)
		let settingsStore: SettingsStore
		do {
			settingsStore = try SettingsStore.load(from: settingsURL)
		} catch {
			NSLog("[MobileAppComposition] Settings load failed: \(error)")
			settingsStore = SettingsStore(
				settings: CatermSettings(global: CatermSettings.defaultsSeed),
				path: settingsURL
			)
		}
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
		let credentialIdentityStore = CredentialIdentityStore(
			fileURL: applicationSupportURL.appendingPathComponent(
				"credential-identities.json"
			)
		)
		Task { @MainActor in
			do {
				try await credentialIdentityStore.load()
			} catch {
				NSLog(
					"[MobileAppComposition] Credential identities failed to load: \(error)"
				)
			}
		}
		let credentialIdentityMaterialStore =
			CredentialIdentityMaterialStore(
				secrets: IdentityKeychainSecretStore(),
				managedKeys: managedKeyStore
			)
		let credentialWriter = MobileCredentialWriter(
			keychain: KeychainStore(
				service: SSHCredentialContract.keychainService,
				accessGroup: nil
			),
			managedKeyStore: managedKeyStore
		)
		let hostStore = MobileHostStore(
			fileURL: hostsURL,
			credentialWriter: credentialWriter,
			managedKeyStore: managedKeyStore,
			credentialMaterialStore: materialStore,
			credentialIdentityStore: credentialIdentityStore
		)
		#if targetEnvironment(simulator)
		seedSimulatorCachedHostIfRequested(
			in: hostStore,
			snippetStore: snippetStore
		)
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
			materialStore: materialStore,
			identityMaterialStore:
				credentialIdentityMaterialStore,
			identityStore: credentialIdentityStore,
			identity: { @MainActor id in
				credentialIdentityStore.identity(id: id)
			}
		)
		let knownHosts = MobileKnownHostsStore(
			fileURL: applicationSupportURL.appendingPathComponent("known_hosts.json")
		)
		let terminalFactory = makeTerminalFactory(
			planProvider: planProvider,
			credentialSync: credentialSync,
			knownHosts: knownHosts
		)
		let remoteFileFactory = makeRemoteFileClientFactory(
			planProvider: planProvider,
			credentialSync: credentialSync,
			knownHosts: knownHosts
		)

		#if targetEnvironment(simulator)
		if let client = simulatorBoundaryClientIfRequested() {
			let snippetClient = OfflineMobileSnippetSyncClient()
			let snippetSync = SnippetSyncStore(
				store: snippetStore,
				client: snippetClient
			)
			let snippetRuntime = MobileSnippetSyncRuntime(
				store: snippetStore,
				sync: snippetSync,
				client: snippetClient,
				isSignedIn: { false },
				refreshAccount: {}
			)
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
				snippetStore: snippetStore,
				snippetSyncRuntime: snippetRuntime,
				settingsStore: settingsStore,
				settingsSync: nil,
				terminalSessionFactory: terminalFactory,
				remoteFileClientFactory: remoteFileFactory,
				transferWorkspace: makeTransferWorkspace(),
				credentialIdentityStore:
					credentialIdentityStore,
				credentialIdentityMaterialStore:
					credentialIdentityMaterialStore,
				prepareCredentialSyncForSave: { transactionIsCurrent in
					try await credentialSyncCoordinator.enable(
						transactionIsCurrent: transactionIsCurrent
					)
				}
			)
		}
		#endif

		guard cloudKitEnabled else {
			let client = OfflineMobileHostSyncClient()
			let snippetClient = OfflineMobileSnippetSyncClient()
			let snippetSync = SnippetSyncStore(
				store: snippetStore,
				client: snippetClient
			)
			let snippetRuntime = MobileSnippetSyncRuntime(
				store: snippetStore,
				sync: snippetSync,
				client: snippetClient,
				isSignedIn: { false },
				refreshAccount: {}
			)
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
				snippetStore: snippetStore,
				snippetSyncRuntime: snippetRuntime,
				settingsStore: settingsStore,
				settingsSync: nil,
				cloudSyncAvailable: simulatorSyncStatusWasRequested,
				terminalSessionFactory: terminalFactory,
				remoteFileClientFactory: remoteFileFactory,
				transferWorkspace: makeTransferWorkspace(),
				credentialIdentityStore:
					credentialIdentityStore,
				credentialIdentityMaterialStore:
					credentialIdentityMaterialStore,
				prepareCredentialSyncForSave: { transactionIsCurrent in
					try await credentialSyncCoordinator.enable(
						transactionIsCurrent: transactionIsCurrent
					)
				}
			)
		}

		let container = containerFactory()
		let client = CloudKitSyncClient(database: container.privateCloudDatabase)
		let accountSession = iCloudAccountSession(provider: container)
		let snippetSync = SnippetSyncStore(store: snippetStore, client: client)
		let snippetRuntime = MobileSnippetSyncRuntime(
			store: snippetStore,
			sync: snippetSync,
			client: client,
			isSignedIn: { accountSession.isSignedIn },
			refreshAccount: { await accountSession.refresh() }
		)
		let settingsSync = SettingsSyncStore(
			store: settingsStore,
			kvs: NSUbiquitousKeyValueStore.default,
			accountSession: accountSession,
			tokenStore: IdentityTokenStore(),
			currentTokenProvider: {
				FileManager.default.ubiquityIdentityToken
					as? (NSObject & NSCoding & NSCopying)
			}
		)
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
				if await client.hasAnySnippetSyncTokens() { return true }
				let hasCredentialState = await MainActor.run {
					credentialSync.prefs.hasIdentityBoundState
				}
				if hasCredentialState { return true }
				let hasSnippetState = await MainActor.run {
					!snippetStore.snippets.isEmpty
						|| !snippetStore.locallyDirtySnippetIDs.isEmpty
						|| !snippetStore.pendingDeletedSnippetIDs.isEmpty
				}
				if hasSnippetState { return true }
				let hasIdentityState = await MainActor.run {
					!credentialIdentityStore.identities.isEmpty
						|| !credentialIdentityStore
							.locallyDirtyIdentityIDs.isEmpty
						|| !credentialIdentityStore
							.pendingDeletedIdentityIDs.isEmpty
				}
				if hasIdentityState { return true }
				return await hostStore.hasIdentityBoundState()
			}
		)
		let credentialIdentityAccountReset =
			CredentialIdentityAccountResetCoordinator(
				store: credentialIdentityStore,
				materialStore: credentialIdentityMaterialStore
			)
		let identityBoundary = MobileAccountIdentityBoundary(
			evaluate: {
				await identityTracker.handleAccountChange(client: client)
			},
			acknowledge: {
				await identityTracker.acknowledgeIdentityChange()
			},
			beginRelatedSyncSuspension: {
				snippetRuntime.beginAccountChangeSuspension()
			},
			drainRelatedSync: {
				await snippetRuntime.drainForAccountChange()
			},
			resetRelatedLocalState: {
				try await credentialIdentityAccountReset
					.resetForAccountChange()
				try snippetRuntime.resetLocalStateForAccountChange()
			},
			allowRelatedLocalMutationsWhileSuspended: {
				snippetRuntime.allowLocalMutationsWhileAccountUnavailable()
			},
			resumeRelatedSync: { identityChanged in
				snippetRuntime.resumeAfterAccountChange(
					identityChanged: identityChanged
				)
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
		let credentialIdentitySync =
			CredentialIdentitySyncCoordinator(
				store: credentialIdentityStore,
				materialStore:
					credentialIdentityMaterialStore,
				client: client,
				masterKeys: masterKeyStore,
				assignedHostIDs: { identityID in
					Set(hostStore.hosts.compactMap { host in
						host.credentialIdentity?.identityID == identityID
							? host.id : nil
					})
				}
			)

		return MobileAppComposition(
			hostStore: hostStore,
			credentialWriter: credentialWriter,
			syncRuntime: runtime,
			snippetStore: snippetStore,
			snippetSyncRuntime: snippetRuntime,
			settingsStore: settingsStore,
			settingsSync: settingsSync,
			terminalSessionFactory: terminalFactory,
			remoteFileClientFactory: remoteFileFactory,
			transferWorkspace: makeTransferWorkspace(),
			credentialIdentityStore: credentialIdentityStore,
			credentialIdentityMaterialStore:
				credentialIdentityMaterialStore,
			prepareCredentialSyncForSave: { transactionIsCurrent in
				try await credentialSyncCoordinator.enable(
					transactionIsCurrent: transactionIsCurrent
				)
			},
			syncCredentialIdentities: {
				guard accountSession.isSignedIn else { return }
				try await credentialIdentitySync.sync()
			},
			startObservingAccountChanges: {
				accountSession.startObservingAccountChanges()
			}
		)
	}

	private static var simulatorSyncStatusWasRequested: Bool {
		MobileSimulatorSyncScenario.current != nil
	}

	private static func makeTransferWorkspace() -> MobileTransferWorkspace {
		let documents = FileManager.default.urls(
			for: .documentDirectory,
			in: .userDomainMask
		).first ?? FileManager.default.temporaryDirectory
		return MobileTransferWorkspace(
			rootURL: documents.appendingPathComponent(
				"Caterm Transfers",
				isDirectory: true
			),
			purgeOrphanedUploads: true
		)
	}

	private static func makeTerminalFactory(
		planProvider: MobileAuthenticationPlanProvider,
		credentialSync: CredentialSyncPreferencesStore,
		knownHosts: MobileKnownHostsStore
	) -> MobileTerminalSessionFactory {
		MobileTerminalSessionFactory { host in
			let authentication = try await resolveAuthentication(
				for: host,
				planProvider: planProvider,
				credentialSync: credentialSync
			)
			let environment = authentication.host.automation.isEnabled
				? try authentication.host.automation
					.validated().environment
				: []
			let transport = NIOSSHTransport(
				host: authentication.host,
				plan: authentication.plan,
				knownHosts: knownHosts,
				environment: environment
			)
			return SSHTerminalSession(
				host: authentication.host,
				transport: transport
			)
		}
	}

	private static func makeRemoteFileClientFactory(
		planProvider: MobileAuthenticationPlanProvider,
		credentialSync: CredentialSyncPreferencesStore,
		knownHosts: MobileKnownHostsStore
	) -> MobileRemoteFileClientFactory {
		MobileRemoteFileClientFactory { host in
			let authentication = try await resolveAuthentication(
				for: host,
				planProvider: planProvider,
				credentialSync: credentialSync
			)
			return MobileRemoteFileClient(
				host: authentication.host,
				plan: authentication.plan,
				knownHosts: knownHosts
			)
		}
	}

	private static func resolveAuthentication(
		for host: SSHHost,
		planProvider: MobileAuthenticationPlanProvider,
		credentialSync: CredentialSyncPreferencesStore
	) async throws -> MobilePreparedAuthentication {
		let result = await planProvider.resolve(
			host: host,
			credentialSyncState: credentialSync.prefs.state
		)
		switch result {
		case .available(let authentication):
			return authentication
		case .unavailable(let reason):
			#if targetEnvironment(simulator)
			if let injected = simulatorPlan(host: host) {
				return MobilePreparedAuthentication(
					host: host,
					plan: injected
				)
			}
			#endif
			throw reason
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
		in store: MobileHostStore,
		snippetStore: SnippetStore
	) {
		#if DEBUG
		let environment = ProcessInfo.processInfo.environment
		guard store.hosts.isEmpty,
			let fixture = MobileSimulatorHostFixture(environment: environment)
		else { return }
		if let snippet = fixture.snippet {
			do {
				try snippetStore.upsert(snippet)
			} catch {
				NSLog("[MobileAppComposition] Simulator snippet seed failed: \(error)")
			}
		}
		Task { @MainActor in
			do {
				try await store.add(fixture.host)
			} catch {
				NSLog("[MobileAppComposition] Simulator Host seed failed: \(error)")
			}
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

struct MobileSimulatorHostFixture: Equatable {
	static let snippetID = UUID(uuid: (
		0xCA, 0x7E, 0x00, 0x00,
		0x00, 0x00,
		0x40, 0x00,
		0x80, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x57
	))
	private static let acceptedEnvironmentID = UUID(uuid: (
		0xCA, 0x7E, 0x00, 0x00,
		0x00, 0x00,
		0x40, 0x00,
		0x80, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0xA1
	))
	private static let rejectedEnvironmentID = UUID(uuid: (
		0xCA, 0x7E, 0x00, 0x00,
		0x00, 0x00,
		0x40, 0x00,
		0x80, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0xB1
	))

	let host: SSHHost
	let snippet: Snippet?

	init?(environment: [String: String]) {
		guard let name = environment["CATERM_SIM_CACHED_HOST_NAME"],
			!name.isEmpty else { return nil }
		let credential: CredentialSource =
			environment["CATERM_SIM_CACHED_HOST_AUTH"] == "password"
				? .password
				: .agent
		let snippet = Self.makeSnippet(environment: environment)
		let automation = snippet.map {
			HostAutomation(
				isEnabled: true,
				startupSnippetID: $0.id,
				environment: Self.environmentVariables(environment),
				reviewPolicy: .always,
				reconnectPolicy: .everyConnection
			)
		} ?? .disabled
		self.host = SSHHost(
			name: name,
			hostname: environment["CATERM_SIM_CACHED_HOST_ADDRESS"]
				?? "offline.example.com",
			port: Int(environment["CATERM_SIM_CACHED_HOST_PORT"] ?? "") ?? 22,
			username: environment["CATERM_SIM_CACHED_HOST_USER"]
				?? "offline",
			credential: credential,
			organization: HostOrganization(tags: ["offline"]),
			automation: automation
		)
		self.snippet = snippet
	}

	private static func makeSnippet(
		environment: [String: String]
	) -> Snippet? {
		guard let command = environment["CATERM_SIM_AUTOMATION_COMMAND"],
			!command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		else { return nil }
		let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
		return Snippet(
			id: snippetID,
			name: "Simulator startup automation",
			content: command,
			createdAt: timestamp,
			updatedAt: timestamp
		)
	}

	private static func environmentVariables(
		_ environment: [String: String]
	) -> [HostEnvironmentVariable] {
		[
			environmentVariable(
				id: acceptedEnvironmentID,
				nameKey: "CATERM_SIM_AUTOMATION_ACCEPTED_NAME",
				valueKey: "CATERM_SIM_AUTOMATION_ACCEPTED_VALUE",
				environment: environment
			),
			environmentVariable(
				id: rejectedEnvironmentID,
				nameKey: "CATERM_SIM_AUTOMATION_REJECTED_NAME",
				valueKey: "CATERM_SIM_AUTOMATION_REJECTED_VALUE",
				environment: environment
			),
		].compactMap { $0 }
	}

	private static func environmentVariable(
		id: UUID,
		nameKey: String,
		valueKey: String,
		environment: [String: String]
	) -> HostEnvironmentVariable? {
		guard let name = environment[nameKey], !name.isEmpty,
			let value = environment[valueKey]
		else { return nil }
		return HostEnvironmentVariable(id: id, name: name, value: value)
	}
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

private final class OfflineMobileSnippetSyncClient: IncrementalSnippetSyncClient,
	@unchecked Sendable {
	func preferredSnippetSyncMode() async -> SnippetSyncMode { .forceFull }

	func fetchSnippetChanges() async throws -> SnippetChangeBatch {
		try await fetchSnippetSnapshotAndCheckpoint()
	}

	func fetchSnippetSnapshotAndCheckpoint() async throws -> SnippetChangeBatch {
		SnippetChangeBatch(
			changedSnippets: [],
			deletedSnippetIDs: [],
			checkpoint: nil,
			tokenExpired: false,
			mode: .forceFull
		)
	}

	func commitSnippetCheckpoint(_: any SnippetSyncCheckpoint) async throws {}
	func resetSnippetSyncState() async {}
	func ensureSnippetSubscription() async throws {}
	func deleteSnippetSubscription() async throws {}
	func hasAnySnippetSyncTokens() async -> Bool { false }

	func pushSnippet(_: Snippet) async throws -> Snippet {
		throw ServerSyncError.notSignedIn
	}

	func deleteSnippet(id _: UUID) async throws {
		throw ServerSyncError.notSignedIn
	}
}
