import SwiftUI
import HostSyncStore
import SettingsStore
import ConfigStore

@MainActor
public struct TerminalSettingsBindings {
    let store: SettingsStore
    public init(store: SettingsStore) { self.store = store }

    public var fontFamily: Binding<String> {
        Binding(
            get: { store.effectiveSettings.global.fontFamily ?? "SF Mono" },
            set: { v in store.update { $0.global.fontFamily = v } }
        )
    }
    public var fontSize: Binding<Int> {
        Binding(
            get: { store.effectiveSettings.global.fontSize ?? 13 },
            set: { v in store.update { $0.global.fontSize = v } }
        )
    }
    public var lineHeight: Binding<Double> {
        Binding(
            get: { store.effectiveSettings.global.lineHeight ?? 1.0 },
            set: { v in store.update { $0.global.lineHeight = v } }
        )
    }
    public var cursorStyle: Binding<CursorStyle> {
        Binding(
            get: { store.effectiveSettings.global.cursorStyle ?? .block },
            set: { v in store.update { $0.global.cursorStyle = v } }
        )
    }
    public var cursorBlink: Binding<Bool> {
        Binding(
            get: { store.effectiveSettings.global.cursorBlink ?? false },
            set: { v in store.update { $0.global.cursorBlink = v } }
        )
    }
    public var bell: Binding<BellMode> {
        Binding(
            get: { store.effectiveSettings.global.bell ?? .visual },
            set: { v in store.update { $0.global.bell = v } }
        )
    }
    public var scrollbackMB: Binding<Int> {
        Binding(
            get: { (store.effectiveSettings.global.scrollbackBytes ?? 10_000_000) / 1_000_000 },
            set: { v in store.update { $0.global.scrollbackBytes = v * 1_000_000 } }
        )
    }
    public var windowOpacity: Binding<Double> {
        Binding(
            get: { store.effectiveSettings.global.windowOpacity ?? 1.0 },
            set: { v in store.update { $0.global.windowOpacity = v } }
        )
    }
    public var windowPaddingX: Binding<Int> {
        Binding(
            get: { store.effectiveSettings.global.windowPaddingX ?? 4 },
            set: { v in store.update { $0.global.windowPaddingX = v } }
        )
    }
    public var windowPaddingY: Binding<Int> {
        Binding(
            get: { store.effectiveSettings.global.windowPaddingY ?? 4 },
            set: { v in store.update { $0.global.windowPaddingY = v } }
        )
    }
}

public struct TerminalSettingsView: View {
    @EnvironmentObject var store: SettingsStore
    /// Sync-adjacent remote-terminal preference (terminfo installation).
    /// Injected from the Settings window's SyncEnvironment; nil (tests,
    /// early boot) hides the Remote section.
    let syncPreferences: SyncPreferences?

    public init(syncPreferences: SyncPreferences? = nil) {
        self.syncPreferences = syncPreferences
    }

    public var body: some View {
        let b = TerminalSettingsBindings(store: store)
        Form {
            Section("Font") {
                FontFamilyPicker(selection: b.fontFamily)
                Stepper("Size: \(b.fontSize.wrappedValue)", value: b.fontSize, in: 8...32)
                Slider(value: b.lineHeight, in: 0.8...2.0, step: 0.05) {
                    Text("Line height: \(b.lineHeight.wrappedValue, specifier: "%.2f")")
                }
            }
            Section("Cursor") {
                Picker("Style", selection: b.cursorStyle) {
                    Text("Block").tag(CursorStyle.block)
                    Text("Bar").tag(CursorStyle.bar)
                    Text("Underline").tag(CursorStyle.underline)
                }
                .pickerStyle(.segmented)
                Toggle("Blink", isOn: b.cursorBlink)
            }
            Section("Bell") {
                Picker("Mode", selection: b.bell) {
                    Text("None").tag(BellMode.none)
                    Text("Audio").tag(BellMode.audio)
                    Text("Visual").tag(BellMode.visual)
                    Text("Both").tag(BellMode.both)
                }
                .pickerStyle(.segmented)
            }
            Section("Scrollback") {
                Stepper("Memory: \(b.scrollbackMB.wrappedValue) MB", value: b.scrollbackMB, in: 1...500)
                Text("Scrollback is stored in memory; larger values use more RAM. Changes apply to new terminals only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Window") {
                Slider(value: b.windowOpacity, in: 0.7...1.0) {
                    Text("Background opacity: \(b.windowOpacity.wrappedValue, specifier: "%.2f")")
                }
                Text("Background opacity applies to new terminals on macOS.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Padding X: \(b.windowPaddingX.wrappedValue)", value: b.windowPaddingX, in: 0...40)
                Stepper("Padding Y: \(b.windowPaddingY.wrappedValue)", value: b.windowPaddingY, in: 0...40)
            }
            if let syncPreferences {
                RemoteTerminalSection(preferences: syncPreferences)
            }
            Section("Advanced") {
                HStack {
                    Button("Edit Advanced Config…") {
                        ConfigStore.revealInFinder(ConfigStore.defaultPath)
                    }
                    Spacer()
                    Text(userOverrideHintText())
                        .foregroundStyle(.secondary).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func userOverrideHintText() -> String {
        let path = ConfigStore.defaultPath
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return "" }
        let entries = GhosttyConfigParser.parse(text)
        let modeled: Set<String> = [
            "font-family", "font-size", "theme", "cursor-style", "cursor-style-blink",
            "bell-features", "scrollback-limit", "background-opacity",
            "window-padding-x", "window-padding-y", "macos-titlebar-style",
            "adjust-cell-height",
        ]
        let count = entries.filter { modeled.contains($0.key) }.count
        return count == 0 ? "" : "\(count) user-config override\(count == 1 ? "" : "s") active"
    }
}

/// "Remote" section: terminfo installation on SSH hosts. Lives on the
/// Terminal page because it configures the remote terminal experience —
/// it is sync-adjacent plumbing (stored in SyncPreferences), not cloud sync.
private struct RemoteTerminalSection: View {
    @ObservedObject var preferences: SyncPreferences

    var body: some View {
        Section("Remote") {
            Toggle(
                "Install Ghostty terminfo on remote hosts",
                isOn: $preferences.installTerminfoEnabled
            )
            Text("Provides full Ghostty rendering features (true colors, hyperlinks). Falls back to standard terminfo automatically if installation isn't possible.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FontFamilyPicker: View {
    @Binding var selection: String
    var body: some View {
        let fonts = monospacedSystemFonts()
        Picker("Family", selection: $selection) {
            ForEach(fonts, id: \.self) { Text($0).tag($0) }
        }
    }
    private func monospacedSystemFonts() -> [String] {
        #if canImport(AppKit)
        let descriptors = NSFontManager.shared.availableFontFamilies
        let mono = descriptors.filter { name in
            let font = NSFont(name: name, size: 12)
            return font?.isFixedPitch == true
        }
        return mono.sorted()
        #else
        return ["SF Mono"]
        #endif
    }
}
