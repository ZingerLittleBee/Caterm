import AppKit
import CloudKit
import CloudKitSyncClient
import ConfigStore
import CredentialIdentitySecurity
import CredentialIdentityStore
import CredentialIdentitySync
import CredentialIdentityRuntime
import CredentialSync
import CredentialSyncStore
import FileTransferStore
import Foundation
import HostAutomationRuntime
import HostKeyProvisioning
import HostSyncStore
import KeychainStore
import ManagedKeyStore
import SFTPCommandBuilder
import SSHCommandBuilder
import SSHCredentialContract
import ServerSyncClient
import SessionHistory
import SessionStore
import SettingsStore
import SettingsSyncStore
import SnippetStore
import SnippetSyncClient
import SwiftUI
import TerminalEngine
import WorkspaceCore
import WorkspaceTemplateStore

@main
struct CatermApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject var store: SessionStore
  @StateObject private var historyStore: SessionHistoryStore
  @StateObject var syncStore: HostSyncStore
  @StateObject var preferences: SyncPreferences
  @StateObject var fileTransferStore: FileTransferStore
  @StateObject var settingsStore: SettingsStore
  @StateObject var remoteBookmarks: RemoteBookmarkStore
  @StateObject private var credentialSync: CredentialSyncPreferencesStore
  @StateObject private var credentialIdentityStore: CredentialIdentityStore
  @StateObject var surfaceRegistry: SurfaceRegistry
  @StateObject private var snippetStore: SnippetStore
  @StateObject private var snippetSync: SnippetSyncStore
  @StateObject private var workspaceCoordinator: WorkspaceCoordinator
  @StateObject private var workspaceTemplateStore: WorkspaceTemplateStore
  private let updaterController = UpdaterController()

  /// Holds the live-reload dispatcher and its NotificationCenter
  /// observer for the app's lifetime. See `LiveReloadCoordinator`.
  let liveReload: LiveReloadCoordinator

  let cloudKitClient: CloudKitSyncClient?
  let icloudSession: any AuthSessionProtocol & AccountSessionProviding
  private let accountChangeSyncCoordinator: AccountChangeSyncCoordinator
  private let settingsSync: SettingsSyncStore
  private let masterKeyStore: KeychainSyncMasterKeyStore
  private let credentialSyncCoordinator: CredentialSyncCoordinator
  private let credentialIdentityMaterialStore: CredentialIdentityMaterialStore
  private let credentialIdentitySyncScheduler: CredentialIdentitySyncScheduler
  private let cloudSyncDisabled: Bool

  init() {
    let cloudSyncDisabled = CloudSyncRuntimeOptions.cloudSyncDisabled()
    self.cloudSyncDisabled = cloudSyncDisabled
    try? ConfigStore.ensureExists(at: ConfigStore.defaultPath)
    let mngs = ManagedKeyStore()
    let identityStore = makeCredentialIdentityStore()
    let identityMaterialStore = CredentialIdentityMaterialStore(
      secrets: IdentityKeychainSecretStore(
        accessGroup: catermAccessGroup()
      ),
      managedKeys: mngs
    )
    _credentialIdentityStore = StateObject(wrappedValue: identityStore)
    self.credentialIdentityMaterialStore = identityMaterialStore
    let history = makeSessionHistoryStore()
    let session = makeStore(
      managedKeyStore: mngs,
      historyRecorder: history,
      credentialIdentityStore: identityStore,
      credentialIdentityMaterialStore: identityMaterialStore
    )
    _historyStore = StateObject(wrappedValue: history)
    let surfaceRegistry = SurfaceRegistry()
    _surfaceRegistry = StateObject(wrappedValue: surfaceRegistry)
    let cloudSync = CloudSyncBootstrap.make(
      disabled: cloudSyncDisabled,
      additionalIdentityBoundState: {
        await MainActor.run {
          !identityStore.identities.isEmpty
            || !identityStore.locallyDirtyIdentityIDs.isEmpty
            || !identityStore.pendingDeletedIdentityIDs.isEmpty
        }
      }
    )
    let icloudSession = cloudSync.accountSession
    self.icloudSession = icloudSession
    self.cloudKitClient = cloudSync.cloudKitClient
    let accountIdentityTracker = cloudSync.accountIdentityTracker
    let prefs = SyncPreferences()
    // Single instances shared across HostSyncStore + Coordinator + UI so
    // toggle/reset state stays consistent.
    let credentialSyncPrefs = CredentialSyncPreferencesStore()
    let mks = KeychainSyncMasterKeyStore()
    self.masterKeyStore = mks
    let credentialCoordinator = CredentialSyncCoordinator(
      prefsStore: credentialSyncPrefs,
      masterKeyStore: mks,
      iCloudKeychainAvailable: { true }
    )
    self.credentialSyncCoordinator = credentialCoordinator
    let identitySyncCoordinator = cloudSync.cloudKitClient.map {
      CredentialIdentitySyncCoordinator(
        store: identityStore,
        materialStore: identityMaterialStore,
        client: $0,
        masterKeys: mks,
        assignedHostIDs: { identityID in
          Set(session.hosts.compactMap { host in
            host.credentialIdentity?.identityID == identityID
              ? host.id : nil
          })
        }
      )
    }
    let identitySyncScheduler = CredentialIdentitySyncScheduler(
      isEnabled: {
        guard identitySyncCoordinator != nil else { return false }
        if case .enabled = credentialSyncPrefs.prefs.state {
          return true
        }
        return false
      },
      sync: {
        guard let identitySyncCoordinator else { return }
        try await identitySyncCoordinator.sync()
      },
      reportFailure: { error in
        NSLog(
          "[CatermApp] Credential identity sync failed: %@",
          String(describing: error)
        )
      }
    )
    self.credentialIdentitySyncScheduler = identitySyncScheduler
    let credentialSyncAccountReset = CredentialSyncAccountResetCoordinator(
      prefsStore: credentialSyncPrefs,
      sessionStore: session
    )
    let credentialIdentityAccountReset =
      CredentialIdentityAccountResetCoordinator(
        store: identityStore,
        materialStore: identityMaterialStore
      )
    _credentialSync = StateObject(wrappedValue: credentialSyncPrefs)
    // `_store = StateObject(wrappedValue:)` is the underscore-prefixed
    // property-wrapper init — required because `@StateObject` cannot be
    // assigned via the synthesized `self.store = ...` syntax in `init`.
    _store = StateObject(wrappedValue: session)
    _preferences = StateObject(wrappedValue: prefs)
    let hostSyncStore = HostSyncStore(
      client: cloudSync.hostClient,
      sessionStore: session,
      authSession: icloudSession,
      preferences: prefs,
      credentialSync: credentialSyncPrefs,
      masterKeyStore: mks
    )
    _syncStore = StateObject(wrappedValue: hostSyncStore)
    // Refresh CloudKit account status asynchronously. HostSyncStore.syncIfSignedIn
    // (called from .task in body) handles the case where refresh hasn't completed
    // yet — it sees isSignedIn=false and skips; the .CKAccountChanged observer
    // re-triggers sync once the status flips.
    if !cloudSyncDisabled {
      Task { @MainActor in
        await icloudSession.refresh()
        NotificationCenter.default.post(
          name: .catermICloudAccountChanged, object: nil
        )
      }
    }
    if !cloudSyncDisabled {
      cloudSync.startObservingAccountChanges()
    }
    // Per-app FileTransferStore. Closures capture plain value types
    // (URLs / paths) rather than `ControlMasterManager` itself so the
    // closure body remains nonisolated-callable. Liveness goes through
    // `ControlMasterManager.shared`'s async `isAlive(hostId:)`, which
    // crosses isolation properly.
    let cmDir =
      (try? CacheDirectories.controlMasterDir())
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let knownCaterm = URL(fileURLWithPath: session.knownHostsCaterm)
    let knownUser = URL(fileURLWithPath: session.knownHostsUser)
    // SettingsStore: loaded eagerly through `BootSequence.run` so the
    // legacy → plist migration (Branch A/B/C), managed-snapshot render,
    // and per-host patch regeneration all run on launch. Per-host theme
    // overrides (Task 24) and the Preferences window (Task 25) share
    // this observable instance. If BootSequence throws (disk fault,
    // permissions issue, etc.), fall back to a defaults-seeded
    // in-memory store so the app still launches — same shape as
    // `PreferencesWindowController`'s fallback.
    let plistPath = SettingsStore.defaultPlistPath
    let settings: SettingsStore
    do {
      settings = try BootSequence.run(
        settingsPlistURL: plistPath,
        userConfigURL: ConfigStore.defaultPath,
        managedSnapshotURL: ConfigStore.managedConfigPath,
        perHostDirectory: ConfigStore.perHostPatchDirectory
      )
    } catch {
      NSLog("[CatermApp] BootSequence failed, using in-memory defaults: \(error)")
      settings = SettingsStore(
        settings: CatermSettings(global: CatermSettings.defaultsSeed),
        path: plistPath
      )
    }
    _settingsStore = StateObject(wrappedValue: settings)
    // Per-host remote-path bookmarks (SFTP file drawer). Lives next to
    // hosts.json under Application Support/Caterm/RemoteBookmarks/<hostId>.json.
    let bookmarksDir = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("Caterm", isDirectory: true)
      .appendingPathComponent("RemoteBookmarks", isDirectory: true)
    let remoteBookmarkStore = RemoteBookmarkStore(directory: bookmarksDir)
    _remoteBookmarks = StateObject(wrappedValue: remoteBookmarkStore)
    // Snippet store: JSON files under Application Support/Caterm/Snippets/.
    // Loaded eagerly so the palette and editor have data on first launch.
    let snippetsDir = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("Caterm", isDirectory: true)
    let snippetStoreInstance = SnippetStore(directory: snippetsDir)
    try? snippetStoreInstance.load()
    _snippetStore = StateObject(wrappedValue: snippetStoreInstance)
    _workspaceCoordinator = StateObject(
      wrappedValue: WorkspaceCoordinator(
        sessionStore: session,
        resolveAutomation: { host in
          HostAutomationResolver.resolve(
            host: host,
            snippets: snippetStoreInstance.snippets
          )
        }
      )
    )
    let workspaceTemplateStoreInstance = WorkspaceTemplateStore(directory: snippetsDir)
    _workspaceTemplateStore = StateObject(wrappedValue: workspaceTemplateStoreInstance)
    Task { @MainActor in
      do {
        try await workspaceTemplateStoreInstance.load()
      } catch {
        NSLog("[CatermApp] Workspace templates failed to load: %@", error.localizedDescription)
      }
    }
    let snippetSyncInstance = SnippetSyncStore(
      store: snippetStoreInstance, client: cloudSync.snippetClient)
    _snippetSync = StateObject(wrappedValue: snippetSyncInstance)
    self.accountChangeSyncCoordinator = AccountChangeSyncCoordinator(
      dependencies: AccountChangeSyncCoordinator.Dependencies(
        beginHostSuspension: {
          hostSyncStore.beginAccountChangeSuspension()
        },
        beginSnippetSuspension: {
          snippetSyncInstance.beginAccountChangeSuspension()
        },
        drainHost: {
          await hostSyncStore.drainForAccountChange()
        },
        drainSnippets: {
          await snippetSyncInstance.drainForAccountChange()
        },
        identityChanged: {
          guard let accountIdentityTracker, let cloudKitClient = cloudSync.cloudKitClient
          else { return false }
          return await accountIdentityTracker.handleAccountChange(client: cloudKitClient)
            == .identityChanged
        },
        resetCredentials: {
          try await credentialSyncAccountReset.resetForAccountChange()
        },
        resetCredentialIdentities: {
          try await credentialIdentityAccountReset.resetForAccountChange()
        },
        wipeSnippets: {
          try snippetStoreInstance.wipeLocal()
        },
        acknowledgeIdentityChange: {
          await accountIdentityTracker?.acknowledgeIdentityChange()
        },
        resumeHost: {
          hostSyncStore.resumeAfterAccountChange()
        },
        resumeSnippets: { identityChanged in
          snippetSyncInstance.resumeAfterAccountChange(identityChanged: identityChanged)
        },
        reportFailure: { error in
          NSLog("[CatermApp] Account-scoped reset failed: %@", String(describing: error))
        }
      )
    )
    _fileTransferStore = StateObject(
      wrappedValue: FileTransferStore(
        controlPathFor: { hostId in
          cmDir.appendingPathComponent("\(hostId.uuidString).sock")
        },
        credentialsFor: { _ in
          SFTPCredentials(
            knownHostsCaterm: knownCaterm,
            knownHostsUser: knownUser,
            strictHostKeyChecking: .acceptNew
          )
        },
        liveness: ControlMasterManager.shared
      ))
    // Wire the live-reload pipeline. `LiveReloadDispatcher` posts
    // `catermNewSurfaceBanner` / `catermConfigDiagnostics`; active
    // terminal surfaces get their Ghostty config rebuilt from disk.
    self.liveReload = LiveReloadCoordinator(
      settingsStore: settings,
      activeSurfaceTabIds: { surfaceRegistry.activeTabIds() },
      reloadApp: {
        GhosttyApp.updateSharedConfigIfInitialized()
      },
      reloadSurface: { tabId in
        guard let surface = surfaceRegistry.surface(for: tabId) else { return }
        let hostId = session.hostId(for: tabId).map { HostId($0.uuidString) }
        surface.applyConfig(hostId: hostId)
      }
    )
    let tokenStore = IdentityTokenStore()
    let kvsAdapter: KVSProtocol = NSUbiquitousKeyValueStore.default
    self.settingsSync = SettingsSyncStore(
      store: settings,
      kvs: kvsAdapter,
      accountSession: icloudSession,
      tokenStore: tokenStore,
      currentTokenProvider: {
        FileManager.default.ubiquityIdentityToken as? (NSObject & NSCoding & NSCopying)
      }
    )
    if !cloudSyncDisabled {
      self.settingsSync.installLifecycleObservers()
      Task { @MainActor [settingsSync = self.settingsSync] in
        await settingsSync.startSync()
      }
    }
    let openSyncSettingsOnLaunch =
      ProcessInfo.processInfo.environment["CATERM_OPEN_SYNC_SETTINGS_ON_LAUNCH"] == "1"
    if openSyncSettingsOnLaunch {
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(400))
        let preferencesWindow = PreferencesWindowController.shared
        preferencesWindow.use(settingsStore: settings)
        preferencesWindow.syncEnvironment = SyncEnvironment(
          authSession: icloudSession,
          syncStore: hostSyncStore,
          preferences: prefs,
          credentialSync: credentialSyncPrefs,
          credentialSyncCoordinator: credentialCoordinator,
          sessionStore: session,
          snippetStore: snippetStoreInstance,
          bookmarkStore: remoteBookmarkStore,
          credentialIdentityStore: identityStore,
          credentialIdentityMaterialStore: identityMaterialStore,
          triggerCredentialIdentitySync: {
            identitySyncScheduler.schedule()
          }
        )
        if openSyncSettingsOnLaunch {
          preferencesWindow.activate(.cloudSync)
        }
        preferencesWindow.showAndActivate()
      }
    }
    // One-time managed-key migration (ADR 0003): relocate external
    // .keyFile paths through the credential transaction actor. It never
    // dirties credentials or bumps updatedAt and cannot race sync writes.
    // Idempotent (already-managed paths are skipped), so every launch is fine.
    Task { @MainActor in
      let summary = await HostKeyProvisioner.migrateExternalKeyPaths(
        sessionStore: session
      )
      if summary.migrated > 0 || summary.skippedUnreadable > 0
        || summary.skippedChanged > 0
      {
        NSLog(
          "[CatermApp] Managed-key migration: %d migrated, %d unreadable, %d changed concurrently, %d already managed",
          summary.migrated, summary.skippedUnreadable,
          summary.skippedChanged, summary.alreadyManaged)
      }
    }
  }

  var body: some Scene {
    // Each tab in the OS-provided native tab bar is one Workspace window in
    // this data-driven group. macOS auto-tabs them because
    // `NSWindow.allowsAutomaticWindowTabbing = true` (AppDelegate).
    //
    // SwiftUI persists the Codable value for window restoration. Workspace
    // state contains only stable identities and a safe Host reference; the
    // coordinator rebuilds a fresh SessionStore mapping at runtime.
    WindowGroup(for: WorkspaceWindowState.self) { $windowState in
      WorkspaceSceneRoot(windowState: $windowState)
      .environmentObject(store)
      .environmentObject(historyStore)
      .environmentObject(syncStore)  // NEW (v1.4)
      .environmentObject(preferences)  // NEW (v1.4)
      .environmentObject(fileTransferStore)
      .environmentObject(settingsStore)
      .environmentObject(remoteBookmarks)
      .environmentObject(surfaceRegistry)
      .environmentObject(snippetStore)
      .environmentObject(snippetSync)
      .environmentObject(credentialIdentityStore)
      .environmentObject(workspaceCoordinator)
      .environmentObject(workspaceTemplateStore)
      .background(
        SyncSettingsCommandBridge {
          let preferencesWindow = PreferencesWindowController.shared
          preferencesWindow.use(settingsStore: settingsStore)
          preferencesWindow.syncEnvironment = SyncEnvironment(
            authSession: icloudSession,
            syncStore: syncStore,
            preferences: preferences,
            credentialSync: credentialSync,
            credentialSyncCoordinator: credentialSyncCoordinator,
            sessionStore: store,
            snippetStore: snippetStore,
            bookmarkStore: remoteBookmarks,
            credentialIdentityStore: credentialIdentityStore,
            credentialIdentityMaterialStore:
              credentialIdentityMaterialStore,
            triggerCredentialIdentitySync: {
              credentialIdentitySyncScheduler.schedule()
            }
          )
          preferencesWindow.activate(.cloudSync)
          preferencesWindow.showAndActivate()
        }
      )
      // .task closure is sync — syncIfSignedIn() returns immediately;
      // the actual sync work runs as an unstructured Task owned by
      // HostSyncStore's scheduler (NOT by this .task modifier). View
      // disappearance does not cancel the sync — that's intentional;
      // cancellation lives in the chain (spec §3.5).
      .task {
        if !cloudSyncDisabled {
          syncStore.syncIfSignedIn()
        }
      }
      .task {
        if !cloudSyncDisabled, let cloudKitClient {
          try? await cloudKitClient.ensureHostSubscription()
        }
      }
      .task {
        credentialIdentitySyncScheduler.schedule()
      }
      .onReceive(
        NotificationCenter.default
          .publisher(for: .catermCloudKitHostChanged)
      ) { _ in
        credentialIdentitySyncScheduler.schedule()
      }
      .task {
        if !cloudSyncDisabled, let cloudKitClient {
          let mode = await cloudKitClient.preferredSnippetSyncMode()
          snippetSync.scheduleSyncPass(mode: mode)
          snippetSync.startForceFullTimer()
        }
      }
      .task {
        if !cloudSyncDisabled, let cloudKitClient {
          try? await cloudKitClient.ensureSnippetSubscription()
        }
      }
      .onReceive(
        NotificationCenter.default
          .publisher(for: .catermCloudKitSnippetChanged)
      ) { _ in
        if !cloudSyncDisabled {
          snippetSync.scheduleSyncPass(mode: .incremental)
        }
      }
      .onReceive(
        NotificationCenter.default
          .publisher(for: .catermICloudAccountChanged)
      ) { _ in
        guard !cloudSyncDisabled else { return }
        accountChangeSyncCoordinator.enqueue()
      }
    } defaultValue: {
      WorkspaceWindowState.landing(id: UUID())
    }
    .commands {
      CatermWindowCommands()
      // ⌘, opens the unified Preferences window (Task 25).
      // "Edit Advanced Config…" inside General still reveals the TOML
      // config in Finder for power users, so no functionality is lost.
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
          let preferencesWindow = PreferencesWindowController.shared
          preferencesWindow.use(settingsStore: settingsStore)
          preferencesWindow.syncEnvironment = SyncEnvironment(
            authSession: icloudSession,
            syncStore: syncStore,
            preferences: preferences,
            credentialSync: credentialSync,
            credentialSyncCoordinator: credentialSyncCoordinator,
            sessionStore: store,
            snippetStore: snippetStore,
            bookmarkStore: remoteBookmarks,
            credentialIdentityStore: credentialIdentityStore,
            credentialIdentityMaterialStore:
              credentialIdentityMaterialStore,
            triggerCredentialIdentitySync: {
              credentialIdentitySyncScheduler.schedule()
            }
          )
          preferencesWindow.showAndActivate()
        }
        .keyboardShortcut(",", modifiers: .command)
      }
      // Sparkle “Check for Updates…” under the app menu, just after
      // “About”. Sparkle owns the in-flight UI and no-ops a concurrent
      // check, so no reactive disabled state is needed.
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          updaterController.checkForUpdates()
        }
      }
      // Edit menu pasteboard commands. Selectors are the standard
      // `NSText.copy/paste/pasteAsPlainText`, which AppKit
      // responder-chain-dispatches; whichever view is first responder
      // (e.g. GhosttySurfaceNSView) handles them.
      CommandGroup(replacing: .pasteboard) {
        Button("Copy") {
          NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("c", modifiers: [.command])

        Button("Paste") {
          NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("v", modifiers: [.command])

        Button("Paste and Match Style") {
          NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("v", modifiers: [.command, .option, .shift])
      }
      // ⌘B toggles the host-list sidebar. NavigationSplitView
      // installs an `NSSplitViewController` in the responder chain
      // that handles `toggleSidebar:`. Use `NSApp.sendAction(_:to:
      // from:)` with `to: nil` so AppKit walks the responder chain
      // from the key window — `firstResponder?.tryToPerform(...)`
      // alone misses the split-view controller because the chain
      // starts a few links above first responder.
      CommandGroup(after: .sidebar) {
        Button("Toggle Sidebar") {
          NSApp.sendAction(
            #selector(NSSplitViewController.toggleSidebar(_:)),
            to: nil,
            from: nil
          )
        }
        .keyboardShortcut("b", modifiers: .command)
      }
      // ⌘⇧F toggles the active window's Files drawer. The target window travels
      // with the notification so background tabs ignore the command.
      CommandGroup(after: .toolbar) {
        Button("Toggle Files Drawer") {
          NotificationCenter.default.post(
            name: .toggleFileDrawer,
            object: WindowCommandScope.activeTargetWindow
          )
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])

        Divider()

        Button("Save Workspace as Template…") {
          NotificationCenter.default.post(
            name: .catermSaveWorkspaceTemplate,
            object: WindowCommandScope.activeTargetWindow
          )
        }

        Button("Manage Workspace Templates…") {
          NotificationCenter.default.post(
            name: .catermManageWorkspaceTemplates,
            object: WindowCommandScope.activeTargetWindow
          )
        }

        Divider()

        Button("Review Command Broadcast…") {
          NotificationCenter.default.post(
            name: .catermStartWorkspaceBroadcast,
            object: WindowCommandScope.activeTargetWindow
          )
        }
        .keyboardShortcut("b", modifiers: [.command, .option])

        Button("Stop Command Broadcast") {
          NotificationCenter.default.post(
            name: .catermStopWorkspaceBroadcast,
            object: WindowCommandScope.activeTargetWindow
          )
        }
        .keyboardShortcut(".", modifiers: [.command, .option])
      }
      CommandMenu("Pane") {
        Button("Split Right") {
          WorkspaceCommandDispatcher.post(.splitRight)
        }
        .keyboardShortcut("d", modifiers: .command)

        Button("Split Down") {
          WorkspaceCommandDispatcher.post(.splitDown)
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])

        Divider()

        Button("Focus Left Pane") {
          WorkspaceCommandDispatcher.post(.focusLeft)
        }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

        Button("Focus Right Pane") {
          WorkspaceCommandDispatcher.post(.focusRight)
        }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

        Button("Focus Pane Above") {
          WorkspaceCommandDispatcher.post(.focusUp)
        }
        .keyboardShortcut(.upArrow, modifiers: [.command, .option])

        Button("Focus Pane Below") {
          WorkspaceCommandDispatcher.post(.focusDown)
        }
        .keyboardShortcut(.downArrow, modifiers: [.command, .option])

        Button("Focus Previous Pane") {
          WorkspaceCommandDispatcher.post(.focusPrevious)
        }
        .keyboardShortcut("[", modifiers: [.command, .option])

        Button("Focus Next Pane") {
          WorkspaceCommandDispatcher.post(.focusNext)
        }
        .keyboardShortcut("]", modifiers: [.command, .option])

        Divider()

        Button("Toggle Focus Mode") {
          WorkspaceCommandDispatcher.post(.toggleFocusMode)
        }
        .keyboardShortcut(.return, modifiers: [.command, .shift])

        Button("Close Pane") {
          WorkspaceCommandDispatcher.post(.closePane)
        }
        .keyboardShortcut("w", modifiers: [.command, .option])
      }
      // Snippet commands: palette (⌘⇧P), new snippet (⌘⇧S), manager.
      // These post notifications that `SnippetCommandObserver` picks up
      // in the key window only, avoiding multi-window broadcast.
      CommandGroup(after: .toolbar) {
        Button("Open Snippet Palette") {
          NotificationCenter.default.post(name: .catermOpenSnippetPalette, object: nil)
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])

        Button("New Snippet…") {
          NotificationCenter.default.post(name: .catermNewSnippet, object: nil)
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])

        Button("Manage Snippets…") {
          NotificationCenter.default.post(name: .catermOpenSnippetManager, object: nil)
        }
      }
      // Help menu → GitHub documentation page.
      CommandGroup(replacing: .help) {
        Link(
          "Caterm Documentation",
          destination: URL(string: "https://github.com/ZingerLittleBee/Caterm")!)
      }
      #if DEBUG
        // Debug menu — only present in DEBUG builds. Exists so UI
        // automation has a top-level menu item it can reliably hit
        // (AX-stable) instead of fighting SwiftUI List row gestures.
        // Posts a notification that `HostListSidebar` picks up and
        // feeds through the real `connect(_:)` path, so the resulting
        // behavior is identical to a sidebar double-click.
        CommandMenu("Debug") {
          Button("Open Workspace for First Host") {
            NotificationCenter.default.post(
              name: .catermDebugOpenFirstHost,
              object: WindowCommandScope.activeTargetWindow
            )
          }
          .keyboardShortcut("o", modifiers: [.control, .option, .command])
        }
      #endif
    }
    Window("Connection History", id: SessionHistoryWindow.id) {
      SessionHistoryView()
        .environmentObject(store)
        .environmentObject(historyStore)
        .environmentObject(preferences)
        .environmentObject(workspaceCoordinator)
    }
    .defaultSize(width: 840, height: 520)
    Window("Hosts", id: HostManagerWindow.id) {
      HostManagerView()
        .environmentObject(store)
        .environmentObject(preferences)
        .environmentObject(workspaceCoordinator)
    }
    .defaultSize(width: 1040, height: 620)
    Window("Port Forwarding", id: PortForwardWorkspaceWindow.id) {
      PortForwardWorkspaceView()
        .environmentObject(store)
        .environmentObject(preferences)
        .environmentObject(workspaceCoordinator)
    }
    .defaultSize(width: 860, height: 520)
    Window("Known Hosts", id: KnownHostsWindow.id) {
      KnownHostsManagerView(
        catermURL: URL(fileURLWithPath: store.knownHostsCaterm),
        userURL: URL(fileURLWithPath: store.knownHostsUser)
      )
    }
    .defaultSize(width: 920, height: 520)
    Window("File Transfer", id: SFTPTaskWindow.id) {
      SFTPTaskWindowView()
        .environmentObject(store)
        .environmentObject(fileTransferStore)
    }
    .defaultSize(width: 1120, height: 700)
  }
}

extension Notification.Name {
  static let catermAddHost = Notification.Name("CatermAddHostNotification")
  static let catermSaveWorkspaceTemplate = Notification.Name(
    "CatermSaveWorkspaceTemplateNotification")
  static let catermManageWorkspaceTemplates = Notification.Name(
    "CatermManageWorkspaceTemplatesNotification")
  static let catermStartWorkspaceBroadcast = Notification.Name(
    "CatermStartWorkspaceBroadcastNotification")
  static let catermStopWorkspaceBroadcast = Notification.Name(
    "CatermStopWorkspaceBroadcastNotification")
}

/// App-wide window commands use SwiftUI's scene action directly. A
/// NotificationCenter bridge here would be mounted once per WindowGroup
/// scene, so one menu action would be multiplied by the number of live windows.
struct CatermWindowCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Window") {
        openWindow(value: WorkspaceWindowState.landing(id: UUID()))
      }
      .keyboardShortcut("n", modifiers: .command)
      Button("New Tab") {
        openWindow(value: WorkspaceWindowState.landing(id: UUID()))
      }
      .keyboardShortcut("t", modifiers: .command)
      Button("New Host…") {
        NotificationCenter.default.post(
          name: .catermAddHost,
          object: WindowCommandScope.activeTargetWindow
        )
      }
      .keyboardShortcut("t", modifiers: [.command, .shift])
    }
    CommandGroup(after: .toolbar) {
      Button("Connection History") {
        openWindow(id: SessionHistoryWindow.id)
      }
      .keyboardShortcut("y", modifiers: [.command, .shift])
      Button("Manage Hosts") {
        openWindow(id: HostManagerWindow.id)
      }
      Button("Port Forwarding") {
        openWindow(id: PortForwardWorkspaceWindow.id)
      }
      Button("Known Hosts") {
        openWindow(id: KnownHostsWindow.id)
      }
      Button("File Transfer") {
        openWindow(id: SFTPTaskWindow.id)
      }
      .keyboardShortcut("f", modifiers: [.command, .option])
    }
  }
}

struct WorkspaceSceneRoot: View {
  @Binding var windowState: WorkspaceWindowState

  @ViewBuilder
  var body: some View {
    if case .workspace(let workspace) = windowState {
      MainWindow(
        workspace: Binding(
          get: { windowState.workspace ?? workspace },
          set: { windowState = .workspace($0) }
        )
      )
      .id(workspace.id)
    } else {
      LandingView(windowState: $windowState)
    }
  }
}

/// Initial landing view shown for a fresh Workspace window.
/// Embeds the Host list sidebar so users can manage Hosts before a Workspace
/// exists. Picking a Host replaces this window's landing value with the new
/// Workspace shell instead of leaving a sibling blank window behind.
struct LandingView: View {
  @Binding var windowState: WorkspaceWindowState
  @EnvironmentObject var snippetStore: SnippetStore
  @EnvironmentObject var snippetSync: SnippetSyncStore
  @State private var presentingPalette = false
  @State private var presentingEditor = false
  @State private var presentingManager = false
  @State private var presentingTemplateManager = false
  @State private var workspaceTemplateMessage: String?
  @State private var hostWindow: NSWindow?

  var body: some View {
    NavigationSplitView {
      HostListSidebar(onOpenWorkspace: { workspace in
        windowState = .workspace(workspace)
      })
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
    } detail: {
      VStack(spacing: 12) {
        Image(systemName: "terminal").font(.system(size: 64))
          .foregroundColor(.secondary)
        Text("Caterm").font(.largeTitle)
        ShortcutReferenceList()
          .padding(.top, 8)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 1000, minHeight: 600)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          presentingTemplateManager = true
        } label: {
          Image(systemName: "rectangle.stack")
        }
        .help("Workspace Templates")
      }
    }
    .background(WindowAccessor(window: $hostWindow))
    .modifier(
      SnippetCommandObserver(
        presentingPalette: $presentingPalette,
        presentingEditor: $presentingEditor,
        presentingManager: $presentingManager,
        isKeyWindow: { hostWindow?.isKeyWindow ?? false }
      )
    )
    .popover(isPresented: $presentingPalette) {
      SnippetPalette(
        store: snippetStore,
        sync: snippetSync,
        capturedSurface: nil,
        onClose: { presentingPalette = false },
        onCreate: {
          presentingPalette = false
          presentingEditor = true
        }
      )
    }
    .sheet(isPresented: $presentingEditor) {
      SnippetEditorSheet(mode: .create)
        .environmentObject(snippetStore)
        .environmentObject(snippetSync)
    }
    .sheet(isPresented: $presentingManager) {
      SnippetManagerSheet()
        .environmentObject(snippetStore)
        .environmentObject(snippetSync)
    }
    .sheet(isPresented: $presentingTemplateManager) {
      WorkspaceTemplateManagerSheet(
        currentWorkspace: nil,
        onOpen: { workspace in
          windowState = .workspace(workspace)
        }
      )
    }
    .onReceive(NotificationCenter.default.publisher(
      for: .catermManageWorkspaceTemplates
    )) { note in
      guard WindowCommandScope.shouldHandle(note, in: hostWindow) else { return }
      presentingTemplateManager = true
    }
    .onReceive(NotificationCenter.default.publisher(
      for: .catermSaveWorkspaceTemplate
    )) { note in
      guard WindowCommandScope.shouldHandle(note, in: hostWindow) else { return }
      workspaceTemplateMessage = "Open a Host before saving a Workspace template."
    }
    .onReceive(NotificationCenter.default.publisher(
      for: .catermStartWorkspaceBroadcast
    )) { note in
      guard WindowCommandScope.shouldHandle(note, in: hostWindow) else { return }
      workspaceTemplateMessage = "Open a Workspace with at least two connected terminal Panes before starting a broadcast."
    }
    .alert(
      "No Active Workspace",
      isPresented: Binding(
        get: { workspaceTemplateMessage != nil },
        set: { if !$0 { workspaceTemplateMessage = nil } }
      ),
      presenting: workspaceTemplateMessage
    ) { _ in
      Button("OK") { workspaceTemplateMessage = nil }
    } message: { message in
      Text(message)
    }
  }
}

@MainActor
private func makeStore(
  managedKeyStore: ManagedKeyStore,
  historyRecorder: SessionHistoryRecording,
  credentialIdentityStore: CredentialIdentityStore,
  credentialIdentityMaterialStore: CredentialIdentityMaterialStore
) -> SessionStore {
  let supportDir = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("Caterm", isDirectory: true)
  try? FileManager.default.createDirectory(
    at: supportDir,
    withIntermediateDirectories: true)
  let environment = ProcessInfo.processInfo.environment
  let knownCaterm = environment["CATERM_KNOWN_HOSTS_PATH"]
    ?? supportDir.appendingPathComponent("known_hosts").path
  let knownUser = environment["CATERM_USER_KNOWN_HOSTS_PATH"]
    ?? ("~/.ssh/known_hosts" as NSString).expandingTildeInPath
  let hostsURL = environment["CATERM_HOSTS_PATH"]
    .map(URL.init(fileURLWithPath:))
    ?? supportDir.appendingPathComponent("hosts.json")

  // Dev: askpass binary path can be overridden via env. In a packaged .app
  // it would sit alongside the main binary in Contents/MacOS/.
  // For a SwiftPM CLI executable, `Bundle.main.executableURL` is the binary
  // itself; its parent directory contains the sibling `caterm-askpass`.
  let askpassPath =
    ProcessInfo.processInfo.environment["CATERM_DEV_ASKPASS_PATH"]
    ?? Bundle.main.executableURL!
    .deletingLastPathComponent()
    .appendingPathComponent("caterm-askpass").path

  // Task 1.3 finding: AMFI rejects keychain-access-groups on dev signing.
  // In dev path we leave accessGroup nil and fall back to the login keychain.
  let teamId = ProcessInfo.processInfo.environment["CATERM_TEAM_ID"] ?? ""
  let accessGroup = teamId.isEmpty ? nil : "\(teamId).caterm.shared"

  let keychain = KeychainStore(
    service: SSHCredentialContract.keychainService,
    accessGroup: accessGroup)

  return SessionStore(
    askpassPath: askpassPath,
    knownHostsCaterm: knownCaterm,
    knownHostsUser: knownUser,
    accessGroup: accessGroup,
    hostsURL: hostsURL,
    keychain: keychain,
    controlMasterManager: ControlMasterManager.shared,
    managedKeyStore: managedKeyStore,
    historyRecorder: historyRecorder,
    credentialIdentityStore: credentialIdentityStore,
    credentialIdentityPreparer: CredentialIdentityConnectionPreparer(
      materialStore: credentialIdentityMaterialStore,
      managedKeyStore: managedKeyStore,
      runtimeSecrets: IdentityKeychainSecretStore(
        accessGroup: accessGroup
      )
    )
  )
}

@MainActor
private func makeCredentialIdentityStore() -> CredentialIdentityStore {
  let supportDirectory = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)
    .first
    ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
  let fileURL = ProcessInfo.processInfo.environment[
    "CATERM_CREDENTIAL_IDENTITIES_PATH"
  ].map(URL.init(fileURLWithPath:))
    ?? supportDirectory
      .appendingPathComponent("Caterm", isDirectory: true)
      .appendingPathComponent("credential-identities.json")
  let store = CredentialIdentityStore(fileURL: fileURL)
  Task { @MainActor in
    do {
      try await store.load()
    } catch {
      NSLog(
        "[CatermApp] Credential identities failed to load: %@",
        String(describing: error)
      )
    }
  }
  return store
}

private func catermAccessGroup() -> String? {
  let teamID = ProcessInfo.processInfo.environment["CATERM_TEAM_ID"] ?? ""
  return teamID.isEmpty ? nil : "\(teamID).caterm.shared"
}

@MainActor
private func makeSessionHistoryStore() -> SessionHistoryStore {
  let environment = ProcessInfo.processInfo.environment
  let fileURL: URL
  if let overridePath = environment["CATERM_SESSION_HISTORY_PATH"] {
    fileURL = URL(fileURLWithPath: overridePath)
  } else {
    let supportDirectory = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first
      ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    fileURL = supportDirectory
      .appendingPathComponent("Caterm", isDirectory: true)
      .appendingPathComponent("session-history.json")
  }
  let store = SessionHistoryStore(fileURL: fileURL)
  do {
    try store.load(recoveringAt: Date())
  } catch {
    NSLog("[CatermApp] Session history load failed: %@", String(describing: error))
  }
  return store
}
