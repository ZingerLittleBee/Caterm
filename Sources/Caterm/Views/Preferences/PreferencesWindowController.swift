import AppKit
import CredentialSync
import CredentialSyncStore
import HostSyncStore
import ManagedKeyStore
import ServerSyncClient
import SessionStore
import SettingsStore
import SnippetStore
import SwiftUI

/// Container the app injects into the window controller so the Sync sections
/// can reach the live iCloud-backed auth surface, `HostSyncStore`, and
/// `SyncPreferences`. Bundled into a single tuple-like struct so unit tests
/// can construct a bare controller without the entire sync stack wired up —
/// the Sync sections then render a placeholder instead of crashing.
@MainActor
public struct SyncEnvironment {
  public let authSession: AuthSessionProtocol
  public let syncStore: HostSyncStore
  public let preferences: SyncPreferences
  public let credentialSync: CredentialSyncPreferencesStore?
  public let credentialSyncCoordinator: CredentialSyncCoordinator?
  public let sessionStore: SessionStore?
  // Backup (encrypted export/import) surface — nil hides the section.
  public let managedKeyStore: ManagedKeyStore?
  public let snippetStore: SnippetStore?
  public let bookmarkStore: RemoteBookmarkStore?

  public init(
    authSession: AuthSessionProtocol,
    syncStore: HostSyncStore,
    preferences: SyncPreferences,
    credentialSync: CredentialSyncPreferencesStore? = nil,
    credentialSyncCoordinator: CredentialSyncCoordinator? = nil,
    sessionStore: SessionStore? = nil,
    managedKeyStore: ManagedKeyStore? = nil,
    snippetStore: SnippetStore? = nil,
    bookmarkStore: RemoteBookmarkStore? = nil
  ) {
    self.authSession = authSession
    self.syncStore = syncStore
    self.preferences = preferences
    self.credentialSync = credentialSync
    self.credentialSyncCoordinator = credentialSyncCoordinator
    self.sessionStore = sessionStore
    self.managedKeyStore = managedKeyStore
    self.snippetStore = snippetStore
    self.bookmarkStore = bookmarkStore
  }
}

/// One entry in the Settings sidebar. System Settings-style navigation:
/// each section is a full detail page, grouped in the sidebar by domain.
public enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
  case terminal
  case themes
  case cloudSync
  case credentials
  case backup

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .terminal: return "Terminal"
    case .themes: return "Themes"
    case .cloudSync: return "iCloud Sync"
    case .credentials: return "Credentials"
    case .backup: return "Backup"
    }
  }

  var systemImage: String {
    switch self {
    case .terminal: return "terminal.fill"
    case .themes: return "paintpalette.fill"
    case .cloudSync: return "icloud.fill"
    case .credentials: return "key.fill"
    case .backup: return "archivebox.fill"
    }
  }

  /// Tint behind the sidebar icon, mirroring System Settings' colored tiles.
  var iconColor: Color {
    switch self {
    case .terminal: return Color(nsColor: .darkGray)
    case .themes: return .purple
    case .cloudSync: return .blue
    case .credentials: return .orange
    case .backup: return .green
    }
  }
}

/// Observable state shared between the AppKit window controller and the
/// SwiftUI `SettingsRootView`: which sidebar section is selected, and the
/// (late-injected) sync stack. Publishing `syncEnvironment` re-renders the
/// Sync sections in place once `CatermApp` wires the stack up — no hosting
/// controller rebuild needed.
@MainActor
public final class SettingsWindowModel: ObservableObject {
  @Published public var selection: SettingsSection = .terminal
  @Published public var syncEnvironment: SyncEnvironment?

  public init() {}
}

@MainActor
public final class PreferencesWindowController: NSWindowController {
  public let model = SettingsWindowModel()
  private var hostingController: NSHostingController<AnyView>?
  public private(set) var settingsStore: SettingsStore

  /// Set by the app once the sync stack is constructed; nil during tests.
  /// Forwarded into the observable model so an assignment after the window
  /// is already visible takes effect immediately.
  public var syncEnvironment: SyncEnvironment? {
    get { model.syncEnvironment }
    set { model.syncEnvironment = newValue }
  }

  public convenience init() {
    let store =
      (try? SettingsStore.load(from: SettingsStore.defaultPlistPath))
      ?? SettingsStore(
        settings: CatermSettings(global: CatermSettings.defaultsSeed),
        path: SettingsStore.defaultPlistPath
      )
    self.init(settingsStore: store)
  }

  public init(settingsStore: SettingsStore) {
    self.settingsStore = settingsStore
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false
    )
    window.title = "Settings"
    window.toolbarStyle = .unified
    window.titlebarSeparatorStyle = .automatic
    window.setFrameAutosaveName("SettingsWindowFrame")
    super.init(window: window)
    installRootView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public func activate(_ section: SettingsSection) {
    model.selection = section
  }

  public func use(settingsStore: SettingsStore) {
    if self.settingsStore === settingsStore { return }
    self.settingsStore = settingsStore
    installRootView()
  }

  private func installRootView() {
    guard let window else { return }
    let root =
      SettingsRootView(model: model)
      .environmentObject(settingsStore)
    let host = NSHostingController(rootView: AnyView(root))
    // Bridge SwiftUI's NavigationSplitView toolbar/title into the NSWindow
    // so the sidebar gets the native full-height material treatment.
    host.sceneBridgingOptions = [.toolbars, .title]
    window.contentViewController = host
    hostingController = host
  }
}

@MainActor
extension PreferencesWindowController {
  /// Process-wide singleton used by ⌘, to surface the Settings window.
  /// The fallback `init()` loads (or seeds) the SettingsStore from the
  /// default plist path, which matches what the rest of the app uses.
  public static let shared: PreferencesWindowController = PreferencesWindowController()

  /// Brings the window on screen and activates the app, even if Caterm
  /// isn't currently frontmost (e.g. the user invoked ⌘, from another app).
  public func showAndActivate() {
    showWindow(self)
    window?.makeKeyAndOrderFront(self)
    NSApp.activate(ignoringOtherApps: true)
  }
}
