import AppKit
import SwiftUI

@MainActor
public final class PreferencesWindowController: NSWindowController {
    public private(set) var tabs: [PreferencesTab] = []
    public private(set) var activeTabIndex: Int = 0
    private var hostingController: NSHostingController<AnyView>?

    public convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Caterm Preferences"
        window.setFrameAutosaveName("PreferencesWindowFrame")
        self.init(window: window)
        self.tabs = [
            PreferencesTab(title: "General", systemImage: "gearshape") { GeneralSettingsView() },
            PreferencesTab(title: "Terminal", systemImage: "terminal") { TerminalSettingsView() },
            PreferencesTab(title: "Themes", systemImage: "paintpalette") { ThemePickerView() },
            PreferencesTab(title: "Sync", systemImage: "icloud") { SyncTabPlaceholderView() },
        ]
        installToolbar()
        renderActiveTab()
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
        let host = NSHostingController(rootView: AnyView(view.frame(minWidth: 600, minHeight: 400)))
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
