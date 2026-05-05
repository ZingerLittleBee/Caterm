import AppKit
import CredentialSync
import CredentialSyncStore
import HostSyncStore
import ServerSyncClient
import SessionStore
import SettingsStore
import SwiftUI

/// Container the app injects into the window controller so the Sync tab can
/// reach the live iCloud-backed auth surface, `HostSyncStore`, and
/// `SyncPreferences`. Bundled into a single tuple-like struct so unit tests
/// can construct a bare controller without the entire sync stack wired up —
/// the Sync tab then renders `SyncTabPlaceholderView` instead of crashing.
@MainActor
public struct SyncEnvironment {
    public let authSession: AuthSessionProtocol
    public let syncStore: HostSyncStore
    public let preferences: SyncPreferences
    public let credentialSync: CredentialSyncPreferencesStore?
    public let credentialSyncCoordinator: CredentialSyncCoordinator?
    public let sessionStore: SessionStore?

    public init(authSession: AuthSessionProtocol,
                syncStore: HostSyncStore,
                preferences: SyncPreferences,
                credentialSync: CredentialSyncPreferencesStore? = nil,
                credentialSyncCoordinator: CredentialSyncCoordinator? = nil,
                sessionStore: SessionStore? = nil) {
        self.authSession = authSession
        self.syncStore = syncStore
        self.preferences = preferences
        self.credentialSync = credentialSync
        self.credentialSyncCoordinator = credentialSyncCoordinator
        self.sessionStore = sessionStore
    }
}

@MainActor
public final class PreferencesWindowController: NSWindowController {
    public private(set) var tabs: [PreferencesTab] = []
    public private(set) var activeTabIndex: Int = 0
    private var hostingController: NSHostingController<AnyView>?
    private let settingsStore: SettingsStore
    /// Set by the app once the sync stack is constructed; nil during tests.
    /// Re-renders the active tab when assigned so a deferred wiring (e.g.
    /// from `CatermApp`'s notification observer) takes effect immediately.
    public var syncEnvironment: SyncEnvironment? {
        didSet { renderActiveTab() }
    }

    public convenience init() {
        let store = (try? SettingsStore.load(from: SettingsStore.defaultPlistPath))
            ?? SettingsStore(
                settings: CatermSettings(global: CatermSettings.defaultsSeed),
                path: SettingsStore.defaultPlistPath
            )
        self.init(settingsStore: store)
    }

    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Caterm Preferences"
        window.setFrameAutosaveName("PreferencesWindowFrame")
        super.init(window: window)
        self.tabs = [
            PreferencesTab(title: "General", systemImage: "gearshape") { GeneralSettingsView() },
            PreferencesTab(title: "Terminal", systemImage: "terminal") { TerminalSettingsView() },
            PreferencesTab(title: "Themes", systemImage: "paintpalette") { ThemePickerView() },
            PreferencesTab(title: "Sync", systemImage: "icloud") { SyncTabPlaceholderView() },
        ]
        installToolbar()
        renderActiveTab()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func activate(tabIndex: Int) {
        guard tabIndex >= 0, tabIndex < tabs.count else { return }
        activeTabIndex = tabIndex
        renderActiveTab()
    }

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "CatermPreferences")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        window?.toolbar = toolbar
    }

    private func renderActiveTab() {
        guard let window else { return }
        let baseView: AnyView
        // Sync tab is special: it needs the AuthSessionProtocol/HostSyncStore/
        // SyncPreferences trio. When the sync environment isn't injected
        // (unit tests, early app boot before CatermApp wires it up) fall
        // back to the placeholder so the controller is constructible
        // without the sync stack. Once `syncEnvironment` is assigned the
        // didSet re-renders this tab and the real Sync UI appears.
        if activeTabIndex == 3, let env = syncEnvironment {
            baseView = AnyView(
                SyncSettingsTab(
                    authSession: env.authSession,
                    syncStore: env.syncStore,
                    preferences: env.preferences,
                    credentialSync: env.credentialSync,
                    credentialSyncCoordinator: env.credentialSyncCoordinator,
                    sessionStore: env.sessionStore
                )
            )
        } else {
            baseView = tabs[activeTabIndex].viewBuilder()
        }
        let rooted = baseView
            .frame(minWidth: 600, minHeight: 400)
            .environmentObject(settingsStore)
        let host = NSHostingController(rootView: AnyView(rooted))
        window.contentViewController = host
        hostingController = host
    }
}

extension PreferencesWindowController: NSToolbarDelegate {
    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        tabs.map { NSToolbarItem.Identifier($0.title) }
    }
    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let index = tabs.firstIndex(where: { $0.title == itemIdentifier.rawValue }) else {
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tabs[index].title
        item.image = NSImage(systemSymbolName: tabs[index].systemImage, accessibilityDescription: nil)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        item.tag = index
        return item
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        activate(tabIndex: sender.tag)
    }
}

@MainActor
public extension PreferencesWindowController {
    /// Process-wide singleton used by ⌘, to surface the Preferences window.
    /// The fallback `init()` loads (or seeds) the SettingsStore from the
    /// default plist path, which matches what the rest of the app uses.
    static let shared: PreferencesWindowController = PreferencesWindowController()

    /// Brings the window on screen and activates the app, even if Caterm
    /// isn't currently frontmost (e.g. the user invoked ⌘, from another app).
    func showAndActivate() {
        showWindow(self)
        window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }
}
