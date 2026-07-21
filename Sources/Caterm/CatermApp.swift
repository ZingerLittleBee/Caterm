import AppKit
import CloudKit
import CloudKitSyncClient
import ConfigStore
import CredentialSync
import CredentialSyncStore
import FileTransferStore
import Foundation
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
  @StateObject var surfaceRegistry: SurfaceRegistry
  @StateObject private var snippetStore: SnippetStore
  @StateObject private var snippetSync: SnippetSyncStore
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
  private let cloudSyncDisabled: Bool

  init() {
    let cloudSyncDisabled = CloudSyncRuntimeOptions.cloudSyncDisabled()
    self.cloudSyncDisabled = cloudSyncDisabled
    try? ConfigStore.ensureExists(at: ConfigStore.defaultPath)
    let mngs = ManagedKeyStore()
    let history = makeSessionHistoryStore()
    let session = makeStore(
      managedKeyStore: mngs,
      historyRecorder: history
    )
    _historyStore = StateObject(wrappedValue: history)
    let surfaceRegistry = SurfaceRegistry()
    _surfaceRegistry = StateObject(wrappedValue: surfaceRegistry)
    let cloudSync = CloudSyncBootstrap.make(disabled: cloudSyncDisabled)
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
    let credentialSyncAccountReset = CredentialSyncAccountResetCoordinator(
      prefsStore: credentialSyncPrefs,
      sessionStore: session
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
          bookmarkStore: remoteBookmarkStore
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
    // Each tab in the OS-provided native tab bar is one window in this
    // `WindowGroup(for: UUID.self)`. macOS auto-tabs them because
    // `NSWindow.allowsAutomaticWindowTabbing = true` (AppDelegate).
    //
    // When `tabId == nil` the user opened a "fresh" window via the
    // File > New Window default; show the landing screen with the host
    // list sidebar.
    WindowGroup(for: UUID.self) { $tabId in
      Group {
        if let id = tabId, store.tabs.contains(where: { $0.id == id }) {
          MainWindow(tabId: id)
        } else {
          // Pass the tabId binding so connecting from this Landing
          // window converts it into the new tab in place instead of
          // spawning a sibling blank tab.
          LandingView(tabId: $tabId)
        }
      }
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
      .background(OpenTabBridge(store: store))
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
      .onReceive(
        NotificationCenter.default
          .publisher(for: .catermOpenSyncSettings)
      ) { _ in
        // Sync settings now live as a tab inside the Preferences
        // window (Task 25). SyncStatusRow still posts this
        // notification when the user clicks the indicator; route
        // it through to the unified Preferences surface.
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
          bookmarkStore: remoteBookmarks
        )
        preferencesWindow.activate(.cloudSync)
        preferencesWindow.showAndActivate()
      }
    }
    .commands {
      // ⌘N opens a fresh LandingView window; ⌘T opens a fresh
      // LandingView as a new *tab* (macOS auto-tabs new windows when
      // `allowsAutomaticWindowTabbing` is on — AppDelegate). Both route
      // through `.catermNewWindow` → `OpenTabBridge` →
      // `openWindow(value: UUID())`, which renders LandingView (the
      // host-selection sidebar). "New Host…" keeps the explicit
      // add-host sheet but no longer owns ⌘T.
      CommandGroup(replacing: .newItem) {
        Button("New Window") {
          NotificationCenter.default.post(name: .catermNewWindow, object: nil)
        }
        .keyboardShortcut("n", modifiers: .command)
        Button("New Tab") {
          NotificationCenter.default.post(name: .catermNewWindow, object: nil)
        }
        .keyboardShortcut("t", modifiers: .command)
        Button("New Host…") {
          NotificationCenter.default.post(name: .catermAddHost, object: nil)
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
      }
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
            bookmarkStore: remoteBookmarks
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
      // ⌘⇧F toggles the per-window Files drawer. The notification is
      // observed by `MainWindow`; broadcasting via NotificationCenter
      // avoids threading window-local @State through App scene.
      CommandGroup(after: .toolbar) {
        Button("Toggle Files Drawer") {
          NotificationCenter.default.post(name: .toggleFileDrawer, object: nil)
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
      }
      CommandGroup(after: .toolbar) {
        Button("Connection History") {
          NotificationCenter.default.post(
            name: .catermOpenSessionHistory,
            object: nil
          )
        }
        .keyboardShortcut("y", modifiers: [.command, .shift])
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
          Button("Open Tab for First Host") {
            NotificationCenter.default.post(
              name: .catermDebugOpenFirstHost, object: nil
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
    }
    .defaultSize(width: 840, height: 520)
  }
}

extension Notification.Name {
  static let catermAddHost = Notification.Name("CatermAddHostNotification")
  static let catermNewWindow = Notification.Name("CatermNewWindowNotification")
  static let catermOpenSessionHistory = Notification.Name(
    "CatermOpenSessionHistoryNotification"
  )
}

/// Invisible bridge view that lets us call `openWindow(value:)` (which needs
/// `@Environment(\.openWindow)` from inside a SwiftUI View) in response to
/// the `.catermNewWindow` notification (⌘N).
///
/// Tab opening from the host list is NOT routed through here — it goes
/// through `HostListSidebar.onOpenTab`, so the owning window can decide
/// whether to swap its own tab identity (Landing case) or spawn a sibling
/// (MainWindow case). Routing it through a global notification used to
/// always spawn a sibling, which left the Landing window around as a blank
/// tab next to the new SSH terminal tab.
struct OpenTabBridge: View {
  @Environment(\.openWindow) var openWindow
  let store: SessionStore

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onReceive(NotificationCenter.default.publisher(for: .catermNewWindow)) { _ in
        // A fresh UUID that is not in store.tabs causes WindowGroup to
        // render LandingView rather than MainWindow — effectively a new
        // blank window in the tab bar.
        openWindow(value: UUID())
      }
      .onReceive(
        NotificationCenter.default.publisher(for: .catermOpenSessionHistory)
      ) { _ in
        openWindow(id: SessionHistoryWindow.id)
      }
  }
}

/// Initial landing view shown when a "fresh" (tabId-less) window opens.
/// Embeds the host list sidebar so users can manage hosts before any tab
/// is open. When the user picks a host, swap our own `tabId` binding to
/// the new tab id — this morphs the current window from Landing into
/// MainWindow rather than spawning a separate window/tab.
struct LandingView: View {
  @Binding var tabId: UUID?
  @EnvironmentObject var snippetStore: SnippetStore
  @EnvironmentObject var snippetSync: SnippetSyncStore
  @State private var presentingPalette = false
  @State private var presentingEditor = false
  @State private var presentingManager = false
  @State private var hostWindow: NSWindow?

  var body: some View {
    NavigationSplitView {
      HostListSidebar(onOpenTab: { newId in tabId = newId })
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
  }
}

@MainActor
private func makeStore(
  managedKeyStore: ManagedKeyStore,
  historyRecorder: SessionHistoryRecording
) -> SessionStore {
  let supportDir = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("Caterm", isDirectory: true)
  try? FileManager.default.createDirectory(
    at: supportDir,
    withIntermediateDirectories: true)
  let knownCaterm = supportDir.appendingPathComponent("known_hosts").path
  let knownUser = ("~/.ssh/known_hosts" as NSString).expandingTildeInPath
  let hostsURL = supportDir.appendingPathComponent("hosts.json")

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
    historyRecorder: historyRecorder)
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
