import AppKit
import SettingsStore
import SwiftUI

@MainActor
public final class PreferencesWindowController: NSWindowController {
    public private(set) var tabs: [PreferencesTab] = []
    public private(set) var activeTabIndex: Int = 0
    private var hostingController: NSHostingController<AnyView>?
    private let settingsStore: SettingsStore

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
        let view = tabs[activeTabIndex].viewBuilder()
        let rooted = view
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
