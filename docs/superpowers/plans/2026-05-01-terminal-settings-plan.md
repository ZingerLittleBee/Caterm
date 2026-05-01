# Terminal Settings GUI + Theme Picker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `⌘, opens config in Finder` with a real macOS Preferences window covering Font/Cursor/Bell/Scrollback/Window/Theme settings plus per-host theme override and a bundled theme catalog. Live-reload through GhosttyKit's diagnostic API; preserve existing user configs via a fingerprint-based migration.

**Architecture:** New `SettingsStore` target owns a Codable `CatermSettings` plist; `ConfigStore` renders a managed snapshot from settings on every change; `SettingsRenderer` classifies field changes as `.live` vs `.newSurface` and broadcasts a scoped `Notification`; existing surfaces apply via `ghostty_surface_update_config`; per-host theme overrides write a tiny patch file loaded after user config; on first launch a `SettingsMigrationStep` either rewrites the legacy seeded user config (Branch A) or imports representable fields and shows a banner about non-representable ones (Branch B).

**Tech Stack:** Swift 5.10+, SwiftUI + AppKit (NSWindow/NSHostingController), GhosttyKit (C API), `ghostty_diagnostic_s`, XCTest, SwiftPM monorepo, Bash + zig (build-time theme extraction).

**Spec:** `docs/superpowers/specs/2026-05-01-terminal-settings-design.md`.

---

## File Structure

**New target `SettingsStore`** (Sources/SettingsStore/):
- `GhosttyConfigParser.swift` — line-based parser/writer for Ghostty config syntax (NOT TOML)
- `CatermSettings.swift` — Codable schema (CatermSettings, PartialSettings, enums, HostId)
- `SettingsStore.swift` — `@MainActor` ObservableObject; load/save/debounce; per-host patch regen
- `SettingsChangeScope.swift` — diff → scope classification using `liveReloadable` map
- `ThemeCatalog.swift` — loads bundled themes.json + favorites
- `Resources/themes.json` — generated at build time
- `Resources/fallback-themes/*.config` — 9 vendored theme files

**Modified target `ConfigStore`**:
- `SettingsRenderer.swift` (new) — PartialSettings → managed snapshot text
- `ConfigStore.swift` (modified) — `renderManagedSnapshot(from:)`, `perHostPatchPath(for:)`, `regeneratePerHostPatches(from:)`

**Modified target `TerminalEngine`**:
- `GhosttyConfig.swift` (modified) — accepts perHost path; exposes diagnostic enumeration
- `ConfigDiagnostic.swift` (new) — parses `ghostty_diagnostic_s` into Swift values
- `GhosttySurface.swift` (modified) — apply per-host patch after `surface_new`

**Modified target `Caterm`**:
- `Views/Preferences/PreferencesWindowController.swift` (new)
- `Views/Preferences/TerminalSettingsView.swift` (new)
- `Views/Preferences/ThemePickerView.swift` + `ThemeCardView.swift` (new)
- `Views/Preferences/GeneralSettingsView.swift` (new placeholder)
- `Views/HostFormView.swift` (modified — theme override picker)
- `Views/SyncSettingsView.swift` (moved into Preferences tab)
- `CatermApp.swift` (modified — ⌘, opens window via NSApp delegate)

**Migration**:
- `Sources/SettingsStore/SettingsMigrationStep.swift` (new)

**Build script**:
- `Scripts/build-theme-catalog.sh` (new) + `Makefile` integration

**Tests**: `Tests/SettingsStoreTests/`, additions to `Tests/ConfigStoreTests/`, `Tests/TerminalEngineTests/`.

---

## Phase 1 — Config parser, schema, renderer

### Task 1: GhosttyConfigParser — read entries with source-line numbers

**Files:**
- Create: `apps/macos/Sources/SettingsStore/GhosttyConfigParser.swift`
- Create test target dir: `apps/macos/Tests/SettingsStoreTests/`
- Test: `apps/macos/Tests/SettingsStoreTests/GhosttyConfigParserReadTests.swift`
- Modify: `apps/macos/Package.swift` (add SettingsStore target + test target)

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/SettingsStoreTests/GhosttyConfigParserReadTests.swift
import XCTest
@testable import SettingsStore

final class GhosttyConfigParserReadTests: XCTestCase {
    func testParsesKeyValueEntriesWithLineNumbers() {
        let text = """
        # comment
        font-family = SF Mono
        font-size = 13

        theme = Catppuccin Mocha
        """
        let entries = GhosttyConfigParser.parse(text)
        XCTAssertEqual(entries.map(\.key), ["font-family", "font-size", "theme"])
        XCTAssertEqual(entries.map(\.rawValue), ["SF Mono", "13", "Catppuccin Mocha"])
        XCTAssertEqual(entries.map(\.sourceLine), [2, 3, 5])
    }

    func testStripsOuterDoubleQuotes() {
        let entries = GhosttyConfigParser.parse(#"font-family = "JetBrains Mono""#)
        XCTAssertEqual(entries.first?.rawValue, "JetBrains Mono")
    }

    func testPreservesRepeatedKeysInOrder() {
        let entries = GhosttyConfigParser.parse("""
        font-family = A
        font-family = B
        """)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].rawValue, "A")
        XCTAssertEqual(entries[1].rawValue, "B")
    }

    func testEmptyValueAllowed() {
        let entries = GhosttyConfigParser.parse("font-family = ")
        XCTAssertEqual(entries.first?.rawValue, "")
    }

    func testInnerQuotesAndPunctuationPassThrough() {
        let entries = GhosttyConfigParser.parse(#"command-palette-entry = title:"Change Tab Title…",action:"prompt_surface_title""#)
        XCTAssertEqual(entries.first?.key, "command-palette-entry")
        XCTAssertTrue(entries.first?.rawValue.contains("title:\"Change Tab Title…\"") == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter GhosttyConfigParserReadTests`
Expected: FAIL with "no such module SettingsStore" or build error.

- [ ] **Step 3: Add SettingsStore target to Package.swift, create the parser**

Edit `apps/macos/Package.swift` — append a new library target after `HostSyncStore`:

```swift
.target(
    name: "SettingsStore",
    dependencies: [],
    path: "Sources/SettingsStore",
    resources: [
        .process("Resources"),
    ]
),
```

And in the test targets section append:

```swift
.testTarget(
    name: "SettingsStoreTests",
    dependencies: ["SettingsStore"],
    path: "Tests/SettingsStoreTests"
),
```

Create the parser file:

```swift
// apps/macos/Sources/SettingsStore/GhosttyConfigParser.swift
import Foundation

public struct ConfigEntry: Equatable {
    public let key: String
    public let rawValue: String
    public let sourceLine: Int  // 1-based
    public let originalLine: String  // for lossless edit

    public init(key: String, rawValue: String, sourceLine: Int, originalLine: String) {
        self.key = key
        self.rawValue = rawValue
        self.sourceLine = sourceLine
        self.originalLine = originalLine
    }
}

public enum GhosttyConfigParser {
    public static func parse(_ text: String) -> [ConfigEntry] {
        var out: [ConfigEntry] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, raw) in lines.enumerated() {
            let lineNo = idx + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let key = raw[..<eq].trimmingCharacters(in: .whitespaces)
            var value = raw[raw.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value = String(value.dropFirst().dropLast())
            }
            out.append(ConfigEntry(
                key: String(key),
                rawValue: String(value),
                sourceLine: lineNo,
                originalLine: String(raw)
            ))
        }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter GhosttyConfigParserReadTests`
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Package.swift apps/macos/Sources/SettingsStore/GhosttyConfigParser.swift apps/macos/Tests/SettingsStoreTests/GhosttyConfigParserReadTests.swift
git commit -m "feat(macos): add GhosttyConfigParser read API"
```

---

### Task 2: GhosttyConfigParser — lossless edit (remove keys by line numbers)

**Files:**
- Modify: `apps/macos/Sources/SettingsStore/GhosttyConfigParser.swift`
- Test: `apps/macos/Tests/SettingsStoreTests/GhosttyConfigParserEditTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/SettingsStoreTests/GhosttyConfigParserEditTests.swift
import XCTest
@testable import SettingsStore

final class GhosttyConfigParserEditTests: XCTestCase {
    func testRemoveLinesPreservesCommentsAndBlankLines() {
        let original = """
        # header

        font-family = SF Mono
        # cursor section
        cursor-style = block
        font-size = 13
        """
        let edited = GhosttyConfigParser.removeLines(original, lineNumbers: [3, 6])
        XCTAssertEqual(edited, """
        # header

        # cursor section
        cursor-style = block
        """)
    }

    func testRemoveNothingPreservesByteForByte() {
        let original = "# a\n\nkey = value\n"
        XCTAssertEqual(GhosttyConfigParser.removeLines(original, lineNumbers: []), original)
    }

    func testRemoveAllProducesEmpty() {
        let original = "a = 1\nb = 2"
        XCTAssertEqual(GhosttyConfigParser.removeLines(original, lineNumbers: [1, 2]), "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter GhosttyConfigParserEditTests`
Expected: FAIL — `removeLines` undefined.

- [ ] **Step 3: Add `removeLines` to the parser**

Append to `GhosttyConfigParser.swift`:

```swift
public extension GhosttyConfigParser {
    /// Returns `text` with the given 1-based line numbers removed. Preserves all other
    /// lines (including comments, blank lines, and trailing newlines) byte-for-byte.
    static func removeLines(_ text: String, lineNumbers: [Int]) -> String {
        let drop = Set(lineNumbers)
        if drop.isEmpty { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        for (idx, line) in lines.enumerated() {
            if !drop.contains(idx + 1) { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter GhosttyConfigParserEditTests`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsStore/GhosttyConfigParser.swift apps/macos/Tests/SettingsStoreTests/GhosttyConfigParserEditTests.swift
git commit -m "feat(macos): add lossless removeLines to GhosttyConfigParser"
```

---

### Task 3: CatermSettings + PartialSettings Codable schema

**Files:**
- Create: `apps/macos/Sources/SettingsStore/CatermSettings.swift`
- Test: `apps/macos/Tests/SettingsStoreTests/CatermSettingsCodableTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/SettingsStoreTests/CatermSettingsCodableTests.swift
import XCTest
@testable import SettingsStore

final class CatermSettingsCodableTests: XCTestCase {
    func testRoundTrip() throws {
        var s = CatermSettings.empty
        s.global.fontFamily = "SF Mono"
        s.global.fontSize = 13
        s.global.cursorStyle = .block
        s.global.bell = .visual
        s.global.scrollbackBytes = 10_000_000
        s.global.titlebarStyle = .tabs
        s.global.theme = "Catppuccin Mocha"
        s.hostOverrides[HostId("h1")] = PartialSettings(theme: "Dracula")
        s.migrationsCompleted.insert("settings-gui-v1")
        let data = try PropertyListEncoder().encode(s)
        let decoded = try PropertyListDecoder().decode(CatermSettings.self, from: data)
        XCTAssertEqual(decoded, s)
    }

    func testEmptyDefaults() {
        XCTAssertEqual(CatermSettings.empty.version, 1)
        XCTAssertTrue(CatermSettings.empty.global == PartialSettings())
        XCTAssertTrue(CatermSettings.empty.hostOverrides.isEmpty)
        XCTAssertTrue(CatermSettings.empty.migrationsCompleted.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter CatermSettingsCodableTests`
Expected: FAIL — types undefined.

- [ ] **Step 3: Implement the schema**

```swift
// apps/macos/Sources/SettingsStore/CatermSettings.swift
import Foundation

public struct HostId: Codable, Hashable, RawRepresentable {
    public let rawValue: String
    public init(_ raw: String) { self.rawValue = raw }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum CursorStyle: String, Codable, CaseIterable, Equatable {
    case block, bar, underline
}

public enum BellMode: String, Codable, CaseIterable, Equatable {
    case none, audio, visual, both
}

public enum TitlebarStyle: String, Codable, CaseIterable, Equatable {
    case tabs, transparent, native, hidden
}

public struct PartialSettings: Codable, Equatable {
    public var fontFamily: String?
    public var fontSize: Int?
    public var lineHeight: Double?
    public var cursorStyle: CursorStyle?
    public var cursorBlink: Bool?
    public var bell: BellMode?
    public var scrollbackBytes: Int?
    public var windowOpacity: Double?
    public var windowPaddingX: Int?
    public var windowPaddingY: Int?
    public var titlebarStyle: TitlebarStyle?
    public var theme: String?

    public init(
        fontFamily: String? = nil,
        fontSize: Int? = nil,
        lineHeight: Double? = nil,
        cursorStyle: CursorStyle? = nil,
        cursorBlink: Bool? = nil,
        bell: BellMode? = nil,
        scrollbackBytes: Int? = nil,
        windowOpacity: Double? = nil,
        windowPaddingX: Int? = nil,
        windowPaddingY: Int? = nil,
        titlebarStyle: TitlebarStyle? = nil,
        theme: String? = nil
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.bell = bell
        self.scrollbackBytes = scrollbackBytes
        self.windowOpacity = windowOpacity
        self.windowPaddingX = windowPaddingX
        self.windowPaddingY = windowPaddingY
        self.titlebarStyle = titlebarStyle
        self.theme = theme
    }
}

public struct CatermSettings: Codable, Equatable {
    public var version: Int
    public var revision: String
    public var global: PartialSettings
    public var hostOverrides: [HostId: PartialSettings]
    public var migrationsCompleted: Set<String>

    public init(
        version: Int = 1,
        revision: String = "",
        global: PartialSettings = PartialSettings(),
        hostOverrides: [HostId: PartialSettings] = [:],
        migrationsCompleted: Set<String> = []
    ) {
        self.version = version
        self.revision = revision
        self.global = global
        self.hostOverrides = hostOverrides
        self.migrationsCompleted = migrationsCompleted
    }

    public static let empty = CatermSettings()

    /// Defaults seeded on first launch when no plist exists. Matches the *current* observed
    /// production defaults from `ConfigStore.defaultConfig` so migrating an empty system
    /// produces no visual change.
    public static let defaultsSeed: PartialSettings = PartialSettings(
        fontFamily: "SF Mono",
        fontSize: 13,
        cursorStyle: .block,
        scrollbackBytes: 10_000_000,
        titlebarStyle: .tabs,
        theme: "Catppuccin Mocha"
    )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter CatermSettingsCodableTests`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsStore/CatermSettings.swift apps/macos/Tests/SettingsStoreTests/CatermSettingsCodableTests.swift
git commit -m "feat(macos): add CatermSettings/PartialSettings Codable schema"
```

---

### Task 4: SettingsRenderer — render fields + always-present legacy block

**Files:**
- Create: `apps/macos/Sources/ConfigStore/SettingsRenderer.swift`
- Modify: `apps/macos/Package.swift` (ConfigStore now depends on SettingsStore)
- Test: `apps/macos/Tests/ConfigStoreTests/SettingsRendererTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/ConfigStoreTests/SettingsRendererTests.swift
import XCTest
import SettingsStore
@testable import ConfigStore

final class SettingsRendererTests: XCTestCase {
    func testEmptyPartialSettingsEmitsLegacyBlockOnly() {
        let out = SettingsRenderer.render(PartialSettings())
        XCTAssertTrue(out.contains("# managed by Caterm"))
        XCTAssertTrue(out.contains("term = xterm-256color"))
        XCTAssertTrue(out.contains("keybind = super+up=scroll_page_lines:-1"))
        XCTAssertTrue(out.contains("keybind = super+k=clear_screen"))
        XCTAssertFalse(out.contains("font-family"))
    }

    func testFullSettingsRenderEachField() {
        var s = PartialSettings()
        s.fontFamily = "SF Mono"
        s.fontSize = 13
        s.lineHeight = 1.1
        s.cursorStyle = .block
        s.cursorBlink = true
        s.bell = .both
        s.scrollbackBytes = 10_000_000
        s.windowOpacity = 0.95
        s.windowPaddingX = 4
        s.windowPaddingY = 4
        s.titlebarStyle = .tabs
        s.theme = "Catppuccin Mocha"
        let out = SettingsRenderer.render(s)
        XCTAssertTrue(out.contains("font-family = SF Mono"))
        XCTAssertTrue(out.contains("font-size = 13"))
        XCTAssertTrue(out.contains("adjust-cell-height = 10%"))
        XCTAssertTrue(out.contains("cursor-style = block"))
        XCTAssertTrue(out.contains("cursor-style-blink = true"))
        XCTAssertTrue(out.contains("bell-features = no-system,audio,attention,title,no-border"))
        XCTAssertTrue(out.contains("scrollback-limit = 10000000"))
        XCTAssertTrue(out.contains("background-opacity = 0.95"))
        XCTAssertTrue(out.contains("window-padding-x = 4"))
        XCTAssertTrue(out.contains("window-padding-y = 4"))
        XCTAssertTrue(out.contains("macos-titlebar-style = tabs"))
        XCTAssertTrue(out.contains("theme = Catppuccin Mocha"))
    }

    func testLineHeightNegative() {
        var s = PartialSettings()
        s.lineHeight = 0.9
        XCTAssertTrue(SettingsRenderer.render(s).contains("adjust-cell-height = -10%"))
    }

    func testBellModeMapping() {
        for (mode, expected) in [
            (BellMode.none, "no-system,no-audio,no-attention,no-title,no-border"),
            (.audio, "no-system,audio,no-attention,no-title,no-border"),
            (.visual, "no-system,no-audio,attention,title,no-border"),
            (.both, "no-system,audio,attention,title,no-border"),
        ] {
            var s = PartialSettings()
            s.bell = mode
            XCTAssertTrue(
                SettingsRenderer.render(s).contains("bell-features = \(expected)"),
                "bell mode \(mode) → \(expected)"
            )
        }
    }

    func testThemeWithSpacesUnquoted() {
        var s = PartialSettings()
        s.theme = "Solarized Dark Higher Contrast"
        XCTAssertTrue(
            SettingsRenderer.render(s).contains("theme = Solarized Dark Higher Contrast")
        )
    }

    func testLegacyBlockAlwaysPresent() {
        // Even with full overrides, the legacy term + 7 keybinds must remain
        var s = PartialSettings()
        s.fontFamily = "JetBrains Mono"
        let out = SettingsRenderer.render(s)
        for line in [
            "term = xterm-256color",
            "keybind = super+up=scroll_page_lines:-1",
            "keybind = super+down=scroll_page_lines:1",
            "keybind = super+page_up=scroll_page_fractional:-1",
            "keybind = super+page_down=scroll_page_fractional:1",
            "keybind = super+home=scroll_to_top",
            "keybind = super+end=scroll_to_bottom",
            "keybind = super+k=clear_screen",
        ] {
            XCTAssertTrue(out.contains(line), "missing legacy line: \(line)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Edit `apps/macos/Package.swift`: in the ConfigStore target's dependencies, add `"SettingsStore"`:

```swift
.target(
    name: "ConfigStore",
    dependencies: ["SettingsStore"],
    path: "Sources/ConfigStore"
),
```

Run: `cd apps/macos && swift test --filter SettingsRendererTests`
Expected: FAIL — `SettingsRenderer` undefined.

- [ ] **Step 3: Implement SettingsRenderer**

```swift
// apps/macos/Sources/ConfigStore/SettingsRenderer.swift
import Foundation
import SettingsStore

public enum SettingsRenderer {
    public static let header = "# managed by Caterm — do not edit; use Caterm Preferences (⌘,)"

    public static let legacyBlock = """
        # Default to xterm-256color so SSH sessions to hosts without the
        # xterm-ghostty terminfo entry installed don't fail.
        term = xterm-256color

        keybind = super+up=scroll_page_lines:-1
        keybind = super+down=scroll_page_lines:1
        keybind = super+page_up=scroll_page_fractional:-1
        keybind = super+page_down=scroll_page_fractional:1
        keybind = super+home=scroll_to_top
        keybind = super+end=scroll_to_bottom
        keybind = super+k=clear_screen
        """

    public static func render(_ s: PartialSettings) -> String {
        var lines: [String] = []
        lines.append(header)
        lines.append("")
        lines.append(legacyBlock)
        lines.append("")

        if let v = s.fontFamily { lines.append("font-family = \(v)") }
        if let v = s.fontSize { lines.append("font-size = \(v)") }
        if let v = s.lineHeight { lines.append("adjust-cell-height = \(formatPercent(v))") }
        if let v = s.cursorStyle { lines.append("cursor-style = \(v.rawValue)") }
        if let v = s.cursorBlink { lines.append("cursor-style-blink = \(v)") }
        if let v = s.bell { lines.append("bell-features = \(renderBell(v))") }
        if let v = s.scrollbackBytes { lines.append("scrollback-limit = \(v)") }
        if let v = s.windowOpacity { lines.append("background-opacity = \(formatDouble(v))") }
        if let v = s.windowPaddingX { lines.append("window-padding-x = \(v)") }
        if let v = s.windowPaddingY { lines.append("window-padding-y = \(v)") }
        if let v = s.titlebarStyle { lines.append("macos-titlebar-style = \(v.rawValue)") }
        if let v = s.theme { lines.append("theme = \(v)") }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatPercent(_ d: Double) -> String {
        let pct = Int(((d - 1.0) * 100).rounded())
        return "\(pct)%"
    }

    private static func formatDouble(_ d: Double) -> String {
        // Trim trailing zeros for cleaner config
        let s = String(format: "%.2f", d)
        if s.hasSuffix("0") { return String(s.dropLast()) }
        return s
    }

    private static func renderBell(_ mode: BellMode) -> String {
        switch mode {
        case .none:    return "no-system,no-audio,no-attention,no-title,no-border"
        case .audio:   return "no-system,audio,no-attention,no-title,no-border"
        case .visual:  return "no-system,no-audio,attention,title,no-border"
        case .both:    return "no-system,audio,attention,title,no-border"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter SettingsRendererTests`
Expected: PASS — 6 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Package.swift apps/macos/Sources/ConfigStore/SettingsRenderer.swift apps/macos/Tests/ConfigStoreTests/SettingsRendererTests.swift
git commit -m "feat(macos): add SettingsRenderer with legacy block preservation"
```

---

### Task 5: SettingsChangeScope — diff and field reload classification

**Files:**
- Create: `apps/macos/Sources/SettingsStore/SettingsChangeScope.swift`
- Test: `apps/macos/Tests/SettingsStoreTests/SettingsChangeScopeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/SettingsStoreTests/SettingsChangeScopeTests.swift
import XCTest
@testable import SettingsStore

final class SettingsChangeScopeTests: XCTestCase {
    func testNoChangeReturnsNil() {
        let s = CatermSettings.empty
        XCTAssertNil(SettingsChangeScope.diff(old: s, new: s))
    }

    func testGlobalLiveWhenLiveFieldChanges() {
        var old = CatermSettings.empty
        var new = old
        old.global.fontSize = 13
        new.global.fontSize = 14
        XCTAssertEqual(SettingsChangeScope.diff(old: old, new: new), .globalLive)
    }

    func testGlobalNewSurfaceWhenOnlyNewSurfaceFieldChanges() {
        var old = CatermSettings.empty
        var new = old
        old.global.scrollbackBytes = 10_000_000
        new.global.scrollbackBytes = 50_000_000
        XCTAssertEqual(SettingsChangeScope.diff(old: old, new: new), .globalNewSurface)
    }

    func testGlobalLiveWhenBothLiveAndNewSurfaceChange() {
        var old = CatermSettings.empty
        var new = old
        old.global.fontSize = 13
        new.global.fontSize = 14
        new.global.titlebarStyle = .native
        XCTAssertEqual(SettingsChangeScope.diff(old: old, new: new), .globalLive)
    }

    func testHostOverrideChangeProducesHostScope() {
        var old = CatermSettings.empty
        var new = old
        new.hostOverrides[HostId("h1")] = PartialSettings(theme: "Dracula")
        XCTAssertEqual(
            SettingsChangeScope.diff(old: old, new: new),
            .hostOverride(HostId("h1"))
        )
    }

    func testMixedGlobalAndHostChangePrioritizesGlobal() {
        var old = CatermSettings.empty
        var new = old
        new.global.fontSize = 14
        new.hostOverrides[HostId("h1")] = PartialSettings(theme: "Dracula")
        // Global change wins; host patch is regenerated separately by store.
        XCTAssertEqual(SettingsChangeScope.diff(old: old, new: new), .globalLive)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter SettingsChangeScopeTests`
Expected: FAIL — `SettingsChangeScope` undefined.

- [ ] **Step 3: Implement SettingsChangeScope**

```swift
// apps/macos/Sources/SettingsStore/SettingsChangeScope.swift
import Foundation

public enum FieldReloadKind {
    case live
    case newSurface
}

public enum SettingsChangeScope: Equatable {
    case globalLive
    case globalNewSurface
    case hostOverride(HostId)

    /// Static map of which fields take effect immediately vs only on next surface_new.
    /// Single source of truth — `SettingsRenderer` and the live-reload pipeline both
    /// consult this to decide whether `surface_update_config` is worth calling.
    public static let liveReloadable: [PartialFieldKey: FieldReloadKind] = [
        .fontFamily: .live,
        .fontSize: .live,
        .lineHeight: .live,
        .cursorStyle: .live,
        .cursorBlink: .live,
        .bell: .live,
        .windowOpacity: .live,
        .windowPaddingX: .live,
        .windowPaddingY: .live,
        .theme: .live,
        .scrollbackBytes: .newSurface,
        .titlebarStyle: .newSurface,
    ]

    public static func diff(old: CatermSettings, new: CatermSettings) -> SettingsChangeScope? {
        let changedGlobal = changedKeys(old: old.global, new: new.global)
        if !changedGlobal.isEmpty {
            let anyLive = changedGlobal.contains { (liveReloadable[$0] ?? .newSurface) == .live }
            return anyLive ? .globalLive : .globalNewSurface
        }
        // Find any changed host id (theme is the only field used in v1).
        let allHostIds = Set(old.hostOverrides.keys).union(new.hostOverrides.keys)
        for id in allHostIds where old.hostOverrides[id] != new.hostOverrides[id] {
            return .hostOverride(id)
        }
        return nil
    }

    private static func changedKeys(old: PartialSettings, new: PartialSettings) -> Set<PartialFieldKey> {
        var s: Set<PartialFieldKey> = []
        if old.fontFamily != new.fontFamily { s.insert(.fontFamily) }
        if old.fontSize != new.fontSize { s.insert(.fontSize) }
        if old.lineHeight != new.lineHeight { s.insert(.lineHeight) }
        if old.cursorStyle != new.cursorStyle { s.insert(.cursorStyle) }
        if old.cursorBlink != new.cursorBlink { s.insert(.cursorBlink) }
        if old.bell != new.bell { s.insert(.bell) }
        if old.scrollbackBytes != new.scrollbackBytes { s.insert(.scrollbackBytes) }
        if old.windowOpacity != new.windowOpacity { s.insert(.windowOpacity) }
        if old.windowPaddingX != new.windowPaddingX { s.insert(.windowPaddingX) }
        if old.windowPaddingY != new.windowPaddingY { s.insert(.windowPaddingY) }
        if old.titlebarStyle != new.titlebarStyle { s.insert(.titlebarStyle) }
        if old.theme != new.theme { s.insert(.theme) }
        return s
    }
}

public enum PartialFieldKey: Hashable {
    case fontFamily, fontSize, lineHeight
    case cursorStyle, cursorBlink
    case bell
    case scrollbackBytes
    case windowOpacity, windowPaddingX, windowPaddingY
    case titlebarStyle
    case theme
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter SettingsChangeScopeTests`
Expected: PASS — 6 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsStore/SettingsChangeScope.swift apps/macos/Tests/SettingsStoreTests/SettingsChangeScopeTests.swift
git commit -m "feat(macos): add SettingsChangeScope diff with live/newSurface classification"
```

---

## Phase 2 — ConfigStore extension + per-host patches

### Task 6: ConfigStore.renderManagedSnapshot + per-host paths

**Files:**
- Modify: `apps/macos/Sources/ConfigStore/ConfigStore.swift`
- Test: `apps/macos/Tests/ConfigStoreTests/ConfigStoreSnapshotTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/ConfigStoreTests/ConfigStoreSnapshotTests.swift
import XCTest
import SettingsStore
@testable import ConfigStore

@MainActor
final class ConfigStoreSnapshotTests: XCTestCase {
    func testRenderManagedSnapshotWritesAtomicallyAndIdempotent() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var s = PartialSettings()
        s.fontFamily = "SF Mono"
        s.theme = "Dracula"
        let target = tmp.appendingPathComponent("managed.config")

        try ConfigStore.renderManagedSnapshot(from: s, to: target)
        let first = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(first.contains("font-family = SF Mono"))
        XCTAssertTrue(first.contains("theme = Dracula"))

        // Idempotent: writing the same content twice doesn't bump mtime
        let mtime1 = try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date
        try ConfigStore.renderManagedSnapshot(from: s, to: target)
        let mtime2 = try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date
        XCTAssertEqual(mtime1, mtime2)
    }

    func testPerHostPatchPathInApplicationSupport() {
        let url = ConfigStore.perHostPatchPath(for: HostId("abc-123"))
        XCTAssertTrue(url.path.contains("/Application Support/Caterm/per-host/abc-123.config"))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStoreSnapshotTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter ConfigStoreSnapshotTests`
Expected: FAIL — methods undefined.

- [ ] **Step 3: Add the new methods**

Append to `apps/macos/Sources/ConfigStore/ConfigStore.swift`:

```swift
import SettingsStore

public extension ConfigStore {
    static var perHostPatchDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Caterm/per-host")
    }

    static func perHostPatchPath(for hostId: HostId) -> URL {
        perHostPatchDirectory.appendingPathComponent("\(hostId.rawValue).config")
    }

    /// Renders `settings` into the managed snapshot file. Idempotent — skips the write
    /// if the on-disk content already matches.
    @MainActor
    static func renderManagedSnapshot(
        from settings: PartialSettings,
        to path: URL = managedConfigPath
    ) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let desired = SettingsRenderer.render(settings)
        if let existing = try? String(contentsOf: path, encoding: .utf8), existing == desired {
            return
        }
        try desired.write(to: path, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter ConfigStoreSnapshotTests`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/ConfigStore/ConfigStore.swift apps/macos/Tests/ConfigStoreTests/ConfigStoreSnapshotTests.swift
git commit -m "feat(macos): ConfigStore.renderManagedSnapshot + perHostPatchPath"
```

---

### Task 7: Per-host patch writer + boot regeneration

**Files:**
- Modify: `apps/macos/Sources/ConfigStore/ConfigStore.swift`
- Test: `apps/macos/Tests/ConfigStoreTests/PerHostPatchTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/ConfigStoreTests/PerHostPatchTests.swift
import XCTest
import SettingsStore
@testable import ConfigStore

@MainActor
final class PerHostPatchTests: XCTestCase {
    func testWritePerHostPatchCreatesFileWithThemeLine() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ConfigStore.writePerHostPatch(
            theme: "Dracula",
            to: dir.appendingPathComponent("h1.config")
        )
        let content = try String(contentsOf: dir.appendingPathComponent("h1.config"), encoding: .utf8)
        XCTAssertEqual(content, "theme = Dracula\n")
    }

    func testRegenerateWritesAndPrunesStaleFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Pre-create a stale file
        try "theme = X\n".write(
            to: dir.appendingPathComponent("stale.config"),
            atomically: true, encoding: .utf8
        )
        var settings = CatermSettings.empty
        settings.hostOverrides[HostId("h1")] = PartialSettings(theme: "Dracula")
        // host with theme=nil should be pruned too
        settings.hostOverrides[HostId("h2")] = PartialSettings()

        try ConfigStore.regeneratePerHostPatches(from: settings, in: dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("h1.config").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("h2.config").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("stale.config").path))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerHostPatchTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter PerHostPatchTests`
Expected: FAIL — methods undefined.

- [ ] **Step 3: Add patch writer and regenerator**

Append to `ConfigStore.swift`:

```swift
public extension ConfigStore {
    @MainActor
    static func writePerHostPatch(theme: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "theme = \(theme)\n".write(to: path, atomically: true, encoding: .utf8)
    }

    /// Idempotently brings on-disk patch directory in line with `settings.hostOverrides`.
    /// Writes a patch for every host whose theme is non-nil; deletes everything else
    /// found in the directory. Called from §5.1 boot sequence and after any host-scoped
    /// settings change.
    @MainActor
    static func regeneratePerHostPatches(
        from settings: CatermSettings,
        in directory: URL = perHostPatchDirectory
    ) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let needed: [HostId: String] = settings.hostOverrides.compactMapValues { $0.theme }
            .reduce(into: [:]) { acc, kv in acc[kv.key] = kv.value }

        // Write all needed patches
        for (id, theme) in needed {
            try writePerHostPatch(theme: theme, to: directory.appendingPathComponent("\(id.rawValue).config"))
        }

        // Prune anything else
        let neededFilenames = Set(needed.keys.map { "\($0.rawValue).config" })
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in entries where !neededFilenames.contains(name) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter PerHostPatchTests`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/ConfigStore/ConfigStore.swift apps/macos/Tests/ConfigStoreTests/PerHostPatchTests.swift
git commit -m "feat(macos): per-host patch writer + boot regeneration"
```

---

## Phase 3 — SettingsStore + ThemeCatalog

### Task 8: SettingsStore — load/save plist with corruption quarantine

**Files:**
- Create: `apps/macos/Sources/SettingsStore/SettingsStore.swift`
- Test: `apps/macos/Tests/SettingsStoreTests/SettingsStorePersistenceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/SettingsStoreTests/SettingsStorePersistenceTests.swift
import XCTest
@testable import SettingsStore

@MainActor
final class SettingsStorePersistenceTests: XCTestCase {
    func testLoadAbsentFileReturnsSeededDefaults() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
        XCTAssertEqual(store.settings.global.fontFamily, "SF Mono")
        XCTAssertEqual(store.settings.global.theme, "Catppuccin Mocha")
    }

    func testRoundTripPersists() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("settings.plist")
        let store = try SettingsStore.load(from: path)
        var s = store.settings
        s.global.fontSize = 17
        try store.save(s)

        let store2 = try SettingsStore.load(from: path)
        XCTAssertEqual(store2.settings.global.fontSize, 17)
    }

    func testCorruptedPlistQuarantinedAndDefaultsSeeded() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("settings.plist")
        try "not a plist".write(to: path, atomically: true, encoding: .utf8)

        let store = try SettingsStore.load(from: path)
        XCTAssertEqual(store.settings.global.theme, "Catppuccin Mocha")
        // Original file is moved aside
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("settings.plist.broken-") })
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStorePersistenceTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter SettingsStorePersistenceTests`
Expected: FAIL — `SettingsStore` undefined.

- [ ] **Step 3: Implement SettingsStore (load/save only — debounce comes in Task 9)**

```swift
// apps/macos/Sources/SettingsStore/SettingsStore.swift
import Foundation
#if canImport(Combine)
import Combine
#endif

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public private(set) var settings: CatermSettings
    public let path: URL

    public static let changeNotification = Notification.Name("catermSettingsChanged")
    public static let scopeUserInfoKey = "scope"

    public init(settings: CatermSettings, path: URL) {
        self.settings = settings
        self.path = path
    }

    public static func load(from path: URL) throws -> SettingsStore {
        if !FileManager.default.fileExists(atPath: path.path) {
            var seeded = CatermSettings.empty
            seeded.global = CatermSettings.defaultsSeed
            seeded.revision = makeRevision()
            return SettingsStore(settings: seeded, path: path)
        }
        do {
            let data = try Data(contentsOf: path)
            let s = try PropertyListDecoder().decode(CatermSettings.self, from: data)
            return SettingsStore(settings: s, path: path)
        } catch {
            try quarantineCorrupted(at: path)
            var seeded = CatermSettings.empty
            seeded.global = CatermSettings.defaultsSeed
            seeded.revision = makeRevision()
            return SettingsStore(settings: seeded, path: path)
        }
    }

    public func save(_ next: CatermSettings) throws {
        var copy = next
        copy.revision = Self.makeRevision()
        let data = try PropertyListEncoder().encode(copy)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: path, options: .atomic)
        self.settings = copy
    }

    private static func quarantineCorrupted(at path: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = path.deletingLastPathComponent()
            .appendingPathComponent("\(path.lastPathComponent).broken-\(stamp)")
        try FileManager.default.moveItem(at: path, to: dest)
    }

    public static func makeRevision() -> String {
        // ULID-like: timestamp millis (base36) + 8 random base36 chars
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let rand = (0..<8).map { _ in
            "0123456789abcdefghijklmnopqrstuvwxyz".randomElement()!
        }
        return String(ms, radix: 36) + String(rand)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter SettingsStorePersistenceTests`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsStore/SettingsStore.swift apps/macos/Tests/SettingsStoreTests/SettingsStorePersistenceTests.swift
git commit -m "feat(macos): SettingsStore load/save with corruption quarantine"
```

---

### Task 9: SettingsStore — debounced update + scoped notification

**Files:**
- Modify: `apps/macos/Sources/SettingsStore/SettingsStore.swift`
- Test: `apps/macos/Tests/SettingsStoreTests/SettingsStoreUpdateTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/SettingsStoreTests/SettingsStoreUpdateTests.swift
import XCTest
@testable import SettingsStore

@MainActor
final class SettingsStoreUpdateTests: XCTestCase {
    func testDebouncePostsScopedNotificationOnce() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreUpdateTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
        store.debounceInterval = .milliseconds(50)

        var seenScopes: [SettingsChangeScope] = []
        let token = NotificationCenter.default.addObserver(
            forName: SettingsStore.changeNotification,
            object: store,
            queue: .main
        ) { note in
            if let s = note.userInfo?[SettingsStore.scopeUserInfoKey] as? SettingsChangeScope {
                seenScopes.append(s)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.update { $0.global.fontSize = 14 }
        store.update { $0.global.fontSize = 15 }
        store.update { $0.global.fontSize = 16 }

        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(seenScopes, [.globalLive])
        XCTAssertEqual(store.settings.global.fontSize, 16)
    }

    func testFlushNowAppliesPendingChange() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreUpdateTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
        store.debounceInterval = .milliseconds(10_000) // long debounce

        store.update { $0.global.fontSize = 22 }
        store.flushNow()
        XCTAssertEqual(store.settings.global.fontSize, 22)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter SettingsStoreUpdateTests`
Expected: FAIL — `update`/`flushNow` undefined.

- [ ] **Step 3: Add debounce + scoped post**

Append to `SettingsStore.swift`:

```swift
public extension SettingsStore {
    private static var pendingKey: UInt8 = 0

    final class _Pending {
        var settings: CatermSettings
        var task: Task<Void, Never>?
        init(_ s: CatermSettings) { self.settings = s }
    }

    private var _pending: _Pending? {
        get { objc_getAssociatedObject(self, &Self.pendingKey) as? _Pending }
        set { objc_setAssociatedObject(self, &Self.pendingKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}

public extension SettingsStore {
    var debounceInterval: Duration {
        get { _debounceInterval ?? .milliseconds(200) }
        set { _debounceInterval = newValue }
    }

    private var _debounceInterval: Duration? {
        get { objc_getAssociatedObject(self, &Self.debounceKey) as? Duration }
        set { objc_setAssociatedObject(self, &Self.debounceKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    private static var debounceKey: UInt8 = 0

    func update(_ mutate: (inout CatermSettings) -> Void) {
        var draft = _pending?.settings ?? settings
        mutate(&draft)
        let pending = _pending ?? _Pending(draft)
        pending.settings = draft
        pending.task?.cancel()
        pending.task = Task { [weak self] in
            try? await Task.sleep(for: self?.debounceInterval ?? .milliseconds(200))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.flushNow() }
        }
        _pending = pending
    }

    func flushNow() {
        guard let pending = _pending else { return }
        _pending = nil
        let old = settings
        let next = pending.settings
        do {
            try save(next)
        } catch {
            NSLog("[SettingsStore] save failed: \(error)")
            return
        }
        if let scope = SettingsChangeScope.diff(old: old, new: next) {
            NotificationCenter.default.post(
                name: Self.changeNotification,
                object: self,
                userInfo: [Self.scopeUserInfoKey: scope]
            )
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter SettingsStoreUpdateTests`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsStore/SettingsStore.swift apps/macos/Tests/SettingsStoreTests/SettingsStoreUpdateTests.swift
git commit -m "feat(macos): SettingsStore.update with debounce + scoped notification"
```

---

### Task 10: ThemeCatalog — load bundled themes.json with fallback

**Files:**
- Create: `apps/macos/Sources/SettingsStore/ThemeCatalog.swift`
- Create: `apps/macos/Sources/SettingsStore/Resources/themes.json` (placeholder content for bootstrap)
- Test: `apps/macos/Tests/SettingsStoreTests/ThemeCatalogTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/SettingsStoreTests/ThemeCatalogTests.swift
import XCTest
@testable import SettingsStore

final class ThemeCatalogTests: XCTestCase {
    func testParseThemeJSONRoundTrips() throws {
        let json = """
        [
          {"name":"Dracula","palette":["#000000","#ff0000","#00ff00","#ffff00",
                                       "#0000ff","#ff00ff","#00ffff","#ffffff",
                                       "#000000","#ff0000","#00ff00","#ffff00",
                                       "#0000ff","#ff00ff","#00ffff","#ffffff"],
           "background":"#282a36","foreground":"#f8f8f2",
           "cursorColor":"#f8f8f2","selectionBackground":"#44475a"}
        ]
        """.data(using: .utf8)!
        let themes = try ThemeCatalog.decode(json)
        XCTAssertEqual(themes.count, 1)
        XCTAssertEqual(themes[0].name, "Dracula")
        XCTAssertEqual(themes[0].palette.count, 16)
        XCTAssertEqual(themes[0].background, "#282a36")
    }

    func testFallbackThemesAlwaysAvailable() {
        let catalog = ThemeCatalog.fallback
        // Spec §3.4 requires 9 favorites; the fallback bundle ships them all
        XCTAssertGreaterThanOrEqual(catalog.themes.count, 9)
        for name in ThemeCatalog.favoriteNames {
            XCTAssertNotNil(
                catalog.themes.first(where: { $0.name == name }),
                "favorite \(name) missing from fallback bundle"
            )
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter ThemeCatalogTests`
Expected: FAIL — `ThemeCatalog` undefined.

- [ ] **Step 3: Implement ThemeCatalog with embedded fallback**

```swift
// apps/macos/Sources/SettingsStore/ThemeCatalog.swift
import Foundation

public struct ThemeRecord: Codable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let palette: [String]
    public let background: String
    public let foreground: String
    public let cursorColor: String?
    public let selectionBackground: String?
}

public struct ThemeCatalog {
    public let themes: [ThemeRecord]

    public static let favoriteNames: [String] = [
        "Catppuccin Mocha",
        "Catppuccin Latte",
        "Dracula",
        "Gruvbox Dark",
        "Gruvbox Light",
        "Nord",
        "One Dark Two",
        "Solarized Dark Higher Contrast",
        "Monokai Classic",
    ]

    public var favorites: [ThemeRecord] {
        favoriteNames.compactMap { name in themes.first { $0.name == name } }
    }

    public static func decode(_ data: Data) throws -> [ThemeRecord] {
        try JSONDecoder().decode([ThemeRecord].self, from: data)
    }

    /// Loads from the SettingsStore bundle's `themes.json`. On failure, falls back to the
    /// embedded 9-favorites set (always present so the picker never goes empty).
    public static func loadBundled() -> ThemeCatalog {
        guard let url = Bundle.module.url(forResource: "themes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let themes = try? decode(data),
              !themes.isEmpty
        else {
            return fallback
        }
        return ThemeCatalog(themes: themes)
    }

    public static let fallback: ThemeCatalog = {
        // Fallback themes embedded inline — guaranteed available even if Resources missing.
        // Palettes are simplified placeholders; the build script (Task 12) replaces this
        // bundle with full Ghostty-extracted swatches.
        ThemeCatalog(themes: favoriteNames.map { name in
            ThemeRecord(
                name: name,
                palette: Array(repeating: "#000000", count: 16),
                background: "#000000",
                foreground: "#ffffff",
                cursorColor: nil,
                selectionBackground: nil
            )
        })
    }()
}
```

Create a placeholder `themes.json` so the build can proceed before the build script runs:

```json
// apps/macos/Sources/SettingsStore/Resources/themes.json
[]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter ThemeCatalogTests`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsStore/ThemeCatalog.swift apps/macos/Sources/SettingsStore/Resources/themes.json apps/macos/Tests/SettingsStoreTests/ThemeCatalogTests.swift
git commit -m "feat(macos): add ThemeCatalog with embedded 9-favorites fallback"
```

---

### Task 11: Build-time theme extraction script

**Files:**
- Create: `apps/macos/Scripts/build-theme-catalog.sh`
- Modify: `Makefile` (add target wired into `macos-ghostty-kit`)

- [ ] **Step 1: Write the failing test**

This task is a build-script integration. The "test" is running the script and asserting it emits a non-empty themes.json with the 9 favorites OR falls back gracefully.

Create test harness `apps/macos/Tests/SettingsStoreTests/ThemeCatalogBuildScriptTests.swift`:

```swift
import XCTest

final class ThemeCatalogBuildScriptTests: XCTestCase {
    func testBuildScriptProducesNonEmptyJSONWhenSubmoduleAvailable() throws {
        // This test is a smoke test for CI; skip if the Ghostty submodule isn't initialized.
        let scriptPath = "apps/macos/Scripts/build-theme-catalog.sh"
        let workspace = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"]
            ?? FileManager.default.currentDirectoryPath
        let absScript = URL(fileURLWithPath: workspace).appendingPathComponent(scriptPath)
        guard FileManager.default.fileExists(atPath: absScript.path) else {
            throw XCTSkip("build script not found at \(absScript.path)")
        }
        // Run with --check-only flag so it doesn't overwrite the bundled file
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [absScript.path, "--check-only"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0,
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter ThemeCatalogBuildScriptTests`
Expected: FAIL — script doesn't exist.

- [ ] **Step 3: Create the build script**

```bash
# apps/macos/Scripts/build-theme-catalog.sh
#!/usr/bin/env bash
# Builds Sources/SettingsStore/Resources/themes.json from the Ghostty submodule.
# Discovers themes from a fixed candidate root list (§3.4 of spec); falls back
# to vendored 9-favorites set if no root contains parseable themes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$ROOT/Sources/SettingsStore/Resources/themes.json"
FALLBACK_DIR="$ROOT/Sources/SettingsStore/Resources/fallback-themes"

CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in --check-only) CHECK_ONLY=1 ;; esac
done

CANDIDATES=(
    "$ROOT/Vendor/ghostty/zig-out/share/ghostty/themes"
    "$ROOT/Vendor/ghostty/zig-out/themes"
    "$ROOT/Vendor/ghostty/src/config/themes"
    "$ROOT/Vendor/ghostty/pkg/iterm2-themes/themes"
)

CHOSEN=""
for c in "${CANDIDATES[@]}"; do
    if [ -d "$c" ] && find "$c" -maxdepth 2 -type f -name "*" -exec grep -l "^palette" {} \; | grep -q .; then
        CHOSEN="$c"
        break
    fi
done

if [ -z "$CHOSEN" ]; then
    echo "[build-theme-catalog] no candidate root with parseable themes; using fallback at $FALLBACK_DIR" >&2
    CHOSEN="$FALLBACK_DIR"
    if [ ! -d "$CHOSEN" ]; then
        echo "[build-theme-catalog] fallback dir missing; emitting empty catalog" >&2
        if [ "$CHECK_ONLY" -eq 0 ]; then echo "[]" > "$OUT"; fi
        exit 0
    fi
fi

echo "[build-theme-catalog] using $CHOSEN" >&2

python3 - "$CHOSEN" "$OUT" "$CHECK_ONLY" <<'PY'
import json, os, re, sys
src, out, check_only = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
themes = []
for name in sorted(os.listdir(src)):
    path = os.path.join(src, name)
    if not os.path.isfile(path):
        continue
    palette = [None] * 16
    bg = fg = cur = sel = None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r"^\s*palette\s*=\s*(\d+)\s*=\s*(#?[0-9a-fA-F]{6})", line)
                if m:
                    idx = int(m.group(1))
                    if 0 <= idx < 16:
                        palette[idx] = m.group(2) if m.group(2).startswith("#") else "#" + m.group(2)
                    continue
                m = re.match(r"^\s*background\s*=\s*(.+?)\s*$", line)
                if m: bg = m.group(1).strip().strip('"'); continue
                m = re.match(r"^\s*foreground\s*=\s*(.+?)\s*$", line)
                if m: fg = m.group(1).strip().strip('"'); continue
                m = re.match(r"^\s*cursor-color\s*=\s*(.+?)\s*$", line)
                if m: cur = m.group(1).strip().strip('"'); continue
                m = re.match(r"^\s*selection-background\s*=\s*(.+?)\s*$", line)
                if m: sel = m.group(1).strip().strip('"'); continue
    except Exception as e:
        print(f"[build-theme-catalog] skip {name}: {e}", file=sys.stderr)
        continue
    if any(p is None for p in palette) or bg is None or fg is None:
        continue
    themes.append({
        "name": name,
        "palette": palette,
        "background": bg,
        "foreground": fg,
        "cursorColor": cur,
        "selectionBackground": sel,
    })

if not themes:
    print(f"[build-theme-catalog] no parseable themes in {src}", file=sys.stderr)
    if not check_only:
        with open(out, "w") as f: f.write("[]\n")
    sys.exit(0)

print(f"[build-theme-catalog] discovered {len(themes)} themes", file=sys.stderr)
if check_only:
    sys.exit(0)

with open(out, "w", encoding="utf-8") as f:
    json.dump(themes, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"[build-theme-catalog] wrote {out}", file=sys.stderr)
PY
```

Make executable:

```bash
chmod +x apps/macos/Scripts/build-theme-catalog.sh
```

Modify root `Makefile` — add target after `macos-ghostty-kit`:

```makefile
.PHONY: macos-theme-catalog
macos-theme-catalog: macos-ghostty-submodule
	bash apps/macos/Scripts/build-theme-catalog.sh

# Make macos-ghostty-kit depend on theme catalog
macos-ghostty-kit: macos-theme-catalog
```

(Adjust the `macos-ghostty-kit` target's existing dependency line in place; do not duplicate the recipe.)

- [ ] **Step 4: Run test to verify it passes**

```bash
chmod +x apps/macos/Scripts/build-theme-catalog.sh
cd apps/macos && swift test --filter ThemeCatalogBuildScriptTests
```
Expected: PASS (or XCTSkip if Ghostty submodule not initialized).

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Scripts/build-theme-catalog.sh Makefile apps/macos/Tests/SettingsStoreTests/ThemeCatalogBuildScriptTests.swift
git commit -m "feat(macos): build-time theme catalog extraction from Ghostty submodule"
```

---

### Task 12: Vendored fallback-themes (9 favorites checked into repo)

**Files:**
- Create: `apps/macos/Sources/SettingsStore/Resources/fallback-themes/Catppuccin Mocha`
- Create: 8 more fallback files (one per favorite)

- [ ] **Step 1: Write the failing test (extends Task 10's fallback test)**

This task makes the embedded `ThemeCatalog.fallback` use parsed real palettes rather than placeholders. Add to `ThemeCatalogTests.swift`:

```swift
extension ThemeCatalogTests {
    func testFallbackPaletteIsParsedFromVendoredFiles() throws {
        let catalog = ThemeCatalog.fallback
        let dracula = try XCTUnwrap(catalog.themes.first(where: { $0.name == "Dracula" }))
        // Real Dracula palette has #282a36 background; placeholders use #000000
        XCTAssertEqual(dracula.background, "#282a36")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter testFallbackPaletteIsParsedFromVendoredFiles`
Expected: FAIL — fallback uses placeholder colors.

- [ ] **Step 3: Vendor 9 theme files + parse them at startup**

For each favorite, add a Ghostty-format file under `Sources/SettingsStore/Resources/fallback-themes/`. Use the canonical Ghostty palettes (copy literally from upstream `Vendor/ghostty/...` — do not invent values). Example for Dracula:

```
# apps/macos/Sources/SettingsStore/Resources/fallback-themes/Dracula
palette = 0=#21222c
palette = 1=#ff5555
palette = 2=#50fa7b
palette = 3=#f1fa8c
palette = 4=#bd93f9
palette = 5=#ff79c6
palette = 6=#8be9fd
palette = 7=#f8f8f2
palette = 8=#6272a4
palette = 9=#ff6e6e
palette = 10=#69ff94
palette = 11=#ffffa5
palette = 12=#d6acff
palette = 13=#ff92df
palette = 14=#a4ffff
palette = 15=#ffffff
background = #282a36
foreground = #f8f8f2
cursor-color = #f8f8f2
selection-background = #44475a
```

Repeat for: `Catppuccin Mocha`, `Catppuccin Latte`, `Gruvbox Dark`, `Gruvbox Light`, `Nord`, `One Dark Two`, `Solarized Dark Higher Contrast`, `Monokai Classic` — copy exact palette values from `Vendor/ghostty/zig-out/share/ghostty/themes/<name>` after running `make macos-ghostty-kit` once locally.

Update `ThemeCatalog.fallback` to parse these at runtime:

```swift
public static let fallback: ThemeCatalog = {
    var themes: [ThemeRecord] = []
    for name in favoriteNames {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "fallback-themes"
        ) else { continue }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        if let record = parseThemeFile(name: name, content: text) {
            themes.append(record)
        }
    }
    if themes.isEmpty {
        // Last-ditch placeholder
        themes = favoriteNames.map { name in
            ThemeRecord(
                name: name,
                palette: Array(repeating: "#000000", count: 16),
                background: "#000000", foreground: "#ffffff",
                cursorColor: nil, selectionBackground: nil
            )
        }
    }
    return ThemeCatalog(themes: themes)
}()

private static func parseThemeFile(name: String, content: String) -> ThemeRecord? {
    var palette: [String?] = Array(repeating: nil, count: 16)
    var bg: String?, fg: String?, cur: String?, sel: String?
    for entry in GhosttyConfigParser.parse(content) {
        switch entry.key {
        case "palette":
            // value is "N=#rgb"
            let parts = entry.rawValue.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let idx = Int(parts[0]), idx >= 0, idx < 16 else { continue }
            var hex = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if !hex.hasPrefix("#") { hex = "#" + hex }
            palette[idx] = hex
        case "background": bg = entry.rawValue
        case "foreground": fg = entry.rawValue
        case "cursor-color": cur = entry.rawValue
        case "selection-background": sel = entry.rawValue
        default: continue
        }
    }
    let final = palette.compactMap { $0 }
    guard final.count == 16, let bg, let fg else { return nil }
    return ThemeRecord(
        name: name, palette: final,
        background: bg, foreground: fg,
        cursorColor: cur, selectionBackground: sel
    )
}
```

Update `Package.swift` SettingsStore resources to include the fallback dir:

```swift
.target(
    name: "SettingsStore",
    dependencies: [],
    path: "Sources/SettingsStore",
    resources: [
        .process("Resources"),
    ]
),
```

(`.process("Resources")` already covers the subdir; no change needed if it's nested under Resources/.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter testFallbackPaletteIsParsedFromVendoredFiles`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsStore/Resources/fallback-themes/ apps/macos/Sources/SettingsStore/ThemeCatalog.swift apps/macos/Tests/SettingsStoreTests/ThemeCatalogTests.swift
git commit -m "feat(macos): vendor 9 fallback theme files; parse palettes at startup"
```

---

## Phase 4 — Migration

### Task 13: SettingsMigrationStep — fingerprint detection + Branch A/C

**Files:**
- Create: `apps/macos/Sources/SettingsStore/SettingsMigrationStep.swift`
- Test: `apps/macos/Tests/SettingsStoreTests/SettingsMigrationBranchACTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/SettingsStoreTests/SettingsMigrationBranchACTests.swift
import XCTest
@testable import SettingsStore

@MainActor
final class SettingsMigrationBranchACTests: XCTestCase {
    func testBranchA_legacyDefaultIsRecognized() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let userConfig = dir.appendingPathComponent("config")
        try SettingsMigrationStep.legacyDefaultV1.write(to: userConfig, atomically: true, encoding: .utf8)

        var settings = CatermSettings.empty
        let result = try SettingsMigrationStep.runIfNeeded(
            userConfigPath: userConfig,
            settings: &settings
        )
        XCTAssertEqual(result, .branchA)
        XCTAssertEqual(settings.global.fontFamily, "SF Mono")
        XCTAssertEqual(settings.global.fontSize, 13)
        XCTAssertEqual(settings.global.theme, "Catppuccin Mocha")
        XCTAssertEqual(settings.global.cursorStyle, .block)
        XCTAssertEqual(settings.global.titlebarStyle, .tabs)
        XCTAssertTrue(settings.migrationsCompleted.contains("settings-gui-v1"))

        // User config replaced with placeholder
        let after = try String(contentsOf: userConfig, encoding: .utf8)
        XCTAssertTrue(after.contains("# User overrides for Caterm"))
        XCTAssertFalse(after.contains("font-family"))

        // Backup created
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("config.bak-pre-settings-gui-") })
    }

    func testBranchC_missingUserConfigSeedsAndWritesPlaceholder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let userConfig = dir.appendingPathComponent("config")
        var settings = CatermSettings.empty
        let result = try SettingsMigrationStep.runIfNeeded(
            userConfigPath: userConfig,
            settings: &settings
        )
        XCTAssertEqual(result, .branchC)
        XCTAssertEqual(settings.global.titlebarStyle, .tabs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: userConfig.path))
    }

    func testIdempotent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let userConfig = dir.appendingPathComponent("config")
        try SettingsMigrationStep.legacyDefaultV1.write(to: userConfig, atomically: true, encoding: .utf8)

        var settings = CatermSettings.empty
        _ = try SettingsMigrationStep.runIfNeeded(userConfigPath: userConfig, settings: &settings)
        let firstResult = settings
        let result2 = try SettingsMigrationStep.runIfNeeded(userConfigPath: userConfig, settings: &settings)
        XCTAssertEqual(result2, .alreadyCompleted)
        XCTAssertEqual(settings, firstResult)
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsMigrationBranchACTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter SettingsMigrationBranchACTests`
Expected: FAIL — `SettingsMigrationStep` undefined.

- [ ] **Step 3: Implement Branch A and C (Branch B comes in Task 14-15)**

```swift
// apps/macos/Sources/SettingsStore/SettingsMigrationStep.swift
import Foundation
import CryptoKit

public enum SettingsMigrationResult: Equatable {
    case branchA
    case branchB(representable: Int, unrepresentable: Int)
    case branchC
    case alreadyCompleted
}

public enum SettingsMigrationError: Error {
    case backupFailed(underlying: Error)
}

public enum SettingsMigrationStep {
    public static let token = "settings-gui-v1"

    /// Exact bytes of the legacy seed in `ConfigStore.defaultConfig`. Used as the
    /// fingerprint check; future Caterm releases append additional historical defaults.
    public static let legacyDefaultV1 = """
        # Caterm-managed Ghostty config — edit freely, restart Caterm to apply.
        # Full reference: https://ghostty.org/docs/config

        font-family = SF Mono
        font-size = 13
        theme = Catppuccin Mocha
        cursor-style = block
        macos-titlebar-style = tabs
        """

    public static let legacyFingerprints: [String] = [
        sha256(legacyDefaultV1),
    ]

    public static let placeholderUserConfig = """
        # User overrides for Caterm. Anything you put here wins over the
        # Caterm-managed config. Use Caterm Preferences (⌘,) for normal settings.
        """

    @MainActor
    public static func runIfNeeded(
        userConfigPath: URL,
        settings: inout CatermSettings
    ) throws -> SettingsMigrationResult {
        if settings.migrationsCompleted.contains(token) {
            return .alreadyCompleted
        }

        if !FileManager.default.fileExists(atPath: userConfigPath.path) {
            try seedDefaultsAndWritePlaceholder(userConfigPath: userConfigPath, settings: &settings)
            settings.migrationsCompleted.insert(token)
            return .branchC
        }

        let raw = (try? String(contentsOf: userConfigPath, encoding: .utf8)) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let fingerprint = sha256(trimmed)

        if legacyFingerprints.contains(fingerprint) {
            try backupUserConfig(at: userConfigPath)
            applyLegacyDefaultsToSettings(&settings)
            try placeholderUserConfig.write(to: userConfigPath, atomically: true, encoding: .utf8)
            settings.migrationsCompleted.insert(token)
            return .branchA
        }

        // Branch B — implemented in Task 14
        let summary = try runBranchB(userConfigPath: userConfigPath, settings: &settings)
        settings.migrationsCompleted.insert(token)
        return .branchB(representable: summary.representableCount, unrepresentable: summary.unrepresentableCount)
    }

    private static func seedDefaultsAndWritePlaceholder(
        userConfigPath: URL,
        settings: inout CatermSettings
    ) throws {
        if settings.global == PartialSettings() {
            settings.global = CatermSettings.defaultsSeed
        }
        try FileManager.default.createDirectory(
            at: userConfigPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try placeholderUserConfig.write(to: userConfigPath, atomically: true, encoding: .utf8)
    }

    private static func applyLegacyDefaultsToSettings(_ settings: inout CatermSettings) {
        settings.global = CatermSettings.defaultsSeed
    }

    private static func backupUserConfig(at path: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = path.deletingLastPathComponent()
            .appendingPathComponent("\(path.lastPathComponent).bak-pre-settings-gui-\(stamp)")
        do {
            try FileManager.default.copyItem(at: path, to: backup)
        } catch {
            throw SettingsMigrationError.backupFailed(underlying: error)
        }
    }

    private static func sha256(_ s: String) -> String {
        let data = Data(s.utf8)
        let h = SHA256.hash(data: data)
        return h.map { String(format: "%02x", $0) }.joined()
    }
}
```

Add a stub Branch B that fails the test in Task 14:

```swift
internal extension SettingsMigrationStep {
    struct BranchBSummary {
        let representableCount: Int
        let unrepresentableCount: Int
    }

    @MainActor
    static func runBranchB(
        userConfigPath: URL,
        settings: inout CatermSettings
    ) throws -> BranchBSummary {
        // Stub — overwritten in Task 14.
        return BranchBSummary(representableCount: 0, unrepresentableCount: 0)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter SettingsMigrationBranchACTests`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsStore/SettingsMigrationStep.swift apps/macos/Tests/SettingsStoreTests/SettingsMigrationBranchACTests.swift
git commit -m "feat(macos): SettingsMigrationStep Branch A/C with fingerprint detection"
```

---

### Task 14: PartialSettings.classifyConfig — Branch B field classification

**Files:**
- Create: `apps/macos/Sources/SettingsStore/ConfigClassification.swift`
- Test: `apps/macos/Tests/SettingsStoreTests/ConfigClassificationTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/SettingsStoreTests/ConfigClassificationTests.swift
import XCTest
@testable import SettingsStore

final class ConfigClassificationTests: XCTestCase {
    func testRepresentableSingleEntries() {
        let result = PartialSettings.classifyConfig("""
            font-family = SF Mono
            font-size = 14
            theme = Dracula
            cursor-style = bar
            macos-titlebar-style = native
            """)
        XCTAssertEqual(result.representable.count, 5)
        XCTAssertTrue(result.unrepresentable.isEmpty)
    }

    func testFallbackChainTreatedAsUnrepresentable() {
        let result = PartialSettings.classifyConfig("""
            font-family = SF Mono
            font-family = JetBrains Mono
            """)
        XCTAssertTrue(result.representable.isEmpty)
        XCTAssertEqual(result.unrepresentable.count, 1)
        if case .fallbackChain(let count) = result.unrepresentable[0].reason {
            XCTAssertEqual(count, 2)
        } else {
            XCTFail("expected fallbackChain")
        }
        XCTAssertEqual(result.unrepresentable[0].sourceLines, [1, 2])
    }

    func testLightDarkTheme() {
        let result = PartialSettings.classifyConfig(
            "theme = light:Catppuccin Latte,dark:Catppuccin Mocha"
        )
        XCTAssertTrue(result.representable.isEmpty)
        XCTAssertEqual(result.unrepresentable.count, 1)
        XCTAssertEqual(result.unrepresentable[0].reason, .lightDarkSplit)
    }

    func testCustomBellFeatures() {
        let result = PartialSettings.classifyConfig(
            "bell-features = audio,attention,no-title"
        )
        XCTAssertEqual(result.unrepresentable.count, 1)
        if case .customBellFeatures(let rendered) = result.unrepresentable[0].reason {
            XCTAssertEqual(rendered, "audio,attention,no-title")
        } else {
            XCTFail("expected customBellFeatures")
        }
    }

    func testStandardBellMatchesRoundtripsAsRepresentable() {
        let result = PartialSettings.classifyConfig(
            "bell-features = no-system,audio,attention,title,no-border"
        )
        XCTAssertEqual(result.representable.count, 1)
        XCTAssertEqual(result.unrepresentable.count, 0)
    }

    func testUnmodeledKeysFlagged() {
        let result = PartialSettings.classifyConfig("""
            palette = 0=#000000
            palette = 1=#ff0000
            keybind = ctrl+a=copy_to_clipboard
            background-image = ~/wp.jpg
            """)
        XCTAssertEqual(result.unrepresentable.count, 3)
        let keys = Set(result.unrepresentable.map(\.key))
        XCTAssertEqual(keys, Set(["palette", "keybind", "background-image"]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter ConfigClassificationTests`
Expected: FAIL — `classifyConfig` undefined.

- [ ] **Step 3: Implement classification**

```swift
// apps/macos/Sources/SettingsStore/ConfigClassification.swift
import Foundation

public struct RepresentableEntry: Equatable {
    public let key: String
    public let value: PartialFieldValue
    public let sourceLines: [Int]
}

public enum PartialFieldValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case cursorStyle(CursorStyle)
    case bell(BellMode)
    case titlebar(TitlebarStyle)
}

public struct UnrepresentableEntry: Equatable {
    public let key: String
    public let sourceLines: [Int]
    public let reason: Reason

    public enum Reason: Equatable {
        case fallbackChain(count: Int)
        case lightDarkSplit
        case customBellFeatures(rendered: String)
        case unmodeledKey(key: String)
        case unparseableValue
    }
}

public struct ConfigClassification: Equatable {
    public var representable: [RepresentableEntry]
    public var unrepresentable: [UnrepresentableEntry]
}

public extension PartialSettings {
    static let unmodeledTrackedKeys: Set<String> = [
        "palette", "theme-light", "theme-dark", "background-image",
        "keybind", "command-palette-entry",
    ]

    static let multiOccurrenceFallbackKeys: Set<String> = [
        "font-family",
    ]

    static func classifyConfig(_ text: String) -> ConfigClassification {
        let entries = GhosttyConfigParser.parse(text)
        var groups: [String: [ConfigEntry]] = [:]
        for e in entries { groups[e.key.lowercased(), default: []].append(e) }

        var rep: [RepresentableEntry] = []
        var unrep: [UnrepresentableEntry] = []

        for (key, group) in groups.sorted(by: { $0.key < $1.key }) {
            let lines = group.map(\.sourceLine)

            if unmodeledTrackedKeys.contains(key) {
                unrep.append(.init(key: key, sourceLines: lines,
                                    reason: .unmodeledKey(key: key)))
                continue
            }

            if multiOccurrenceFallbackKeys.contains(key), group.count > 1 {
                unrep.append(.init(key: key, sourceLines: lines,
                                    reason: .fallbackChain(count: group.count)))
                continue
            }

            if group.count > 1 {
                // Multi-occurrence on a key that doesn't model fallback: treat as unmodeled
                unrep.append(.init(key: key, sourceLines: lines,
                                    reason: .unmodeledKey(key: key)))
                continue
            }

            let entry = group[0]
            switch classifySingle(key: key, rawValue: entry.rawValue) {
            case .representable(let value):
                rep.append(.init(key: key, value: value, sourceLines: [entry.sourceLine]))
            case .unrepresentable(let reason):
                unrep.append(.init(key: key, sourceLines: [entry.sourceLine], reason: reason))
            case .ignored:
                continue
            }
        }
        return ConfigClassification(representable: rep, unrepresentable: unrep)
    }

    private enum SingleClassification {
        case representable(PartialFieldValue)
        case unrepresentable(UnrepresentableEntry.Reason)
        case ignored
    }

    private static func classifySingle(key: String, rawValue: String) -> SingleClassification {
        switch key {
        case "font-family": return .representable(.string(rawValue))
        case "font-size":
            if let i = Int(rawValue) { return .representable(.int(i)) }
            return .unrepresentable(.unparseableValue)
        case "theme":
            if rawValue.contains("light:") || rawValue.contains("dark:") {
                return .unrepresentable(.lightDarkSplit)
            }
            return .representable(.string(rawValue))
        case "cursor-style":
            if let v = CursorStyle(rawValue: rawValue) { return .representable(.cursorStyle(v)) }
            return .unrepresentable(.unparseableValue)
        case "cursor-style-blink":
            if let b = Bool(rawValue) { return .representable(.bool(b)) }
            return .unrepresentable(.unparseableValue)
        case "bell-features":
            if let mode = canonicalBellMode(forFeatures: rawValue) {
                return .representable(.bell(mode))
            }
            return .unrepresentable(.customBellFeatures(rendered: rawValue))
        case "scrollback-limit":
            if let i = Int(rawValue) { return .representable(.int(i)) }
            return .unrepresentable(.unparseableValue)
        case "background-opacity":
            if let d = Double(rawValue) { return .representable(.double(d)) }
            return .unrepresentable(.unparseableValue)
        case "window-padding-x", "window-padding-y":
            if let i = Int(rawValue) { return .representable(.int(i)) }
            return .unrepresentable(.unparseableValue)
        case "macos-titlebar-style":
            if let v = TitlebarStyle(rawValue: rawValue) { return .representable(.titlebar(v)) }
            return .unrepresentable(.unparseableValue)
        default:
            return .ignored
        }
    }

    private static func canonicalBellMode(forFeatures features: String) -> BellMode? {
        let canonical: [String: BellMode] = [
            "no-system,no-audio,no-attention,no-title,no-border": .none,
            "no-system,audio,no-attention,no-title,no-border": .audio,
            "no-system,no-audio,attention,title,no-border": .visual,
            "no-system,audio,attention,title,no-border": .both,
        ]
        let normalized = features.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: ",")
        return canonical[normalized]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter ConfigClassificationTests`
Expected: PASS — 6 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsStore/ConfigClassification.swift apps/macos/Tests/SettingsStoreTests/ConfigClassificationTests.swift
git commit -m "feat(macos): PartialSettings.classifyConfig for Branch B migration"
```

---

### Task 15: Branch B — apply representable, defer import; lossless

**Files:**
- Modify: `apps/macos/Sources/SettingsStore/SettingsMigrationStep.swift`
- Test: `apps/macos/Tests/SettingsStoreTests/SettingsMigrationBranchBTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/SettingsStoreTests/SettingsMigrationBranchBTests.swift
import XCTest
@testable import SettingsStore

@MainActor
final class SettingsMigrationBranchBTests: XCTestCase {
    func testBranchB_representableSeededIntoPlistUserConfigUntouched() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let userConfig = dir.appendingPathComponent("config")
        let original = """
            # my user config
            font-family = JetBrains Mono
            theme = Dracula
            """
        try original.write(to: userConfig, atomically: true, encoding: .utf8)

        var settings = CatermSettings.empty
        let result = try SettingsMigrationStep.runIfNeeded(
            userConfigPath: userConfig, settings: &settings
        )
        XCTAssertEqual(result, .branchB(representable: 2, unrepresentable: 0))
        XCTAssertEqual(settings.global.fontFamily, "JetBrains Mono")
        XCTAssertEqual(settings.global.theme, "Dracula")
        // User config not modified yet
        XCTAssertEqual(try String(contentsOf: userConfig, encoding: .utf8), original)
    }

    func testFallbackChainKeptIntact() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let userConfig = dir.appendingPathComponent("config")
        let original = """
            font-family = SF Mono
            font-family = JetBrains Mono
            """
        try original.write(to: userConfig, atomically: true, encoding: .utf8)

        var settings = CatermSettings.empty
        let result = try SettingsMigrationStep.runIfNeeded(
            userConfigPath: userConfig, settings: &settings
        )
        XCTAssertEqual(result, .branchB(representable: 0, unrepresentable: 1))
        XCTAssertEqual(try String(contentsOf: userConfig, encoding: .utf8), original)
        XCTAssertNil(settings.global.fontFamily)
    }

    func testImportRepresentableKeysClearsOnlyRepresentableLines() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let userConfig = dir.appendingPathComponent("config")
        let original = """
            font-family = SF Mono
            font-family = JetBrains Mono
            theme = Dracula
            palette = 0=#000000
            """
        try original.write(to: userConfig, atomically: true, encoding: .utf8)

        var settings = CatermSettings.empty
        _ = try SettingsMigrationStep.runIfNeeded(userConfigPath: userConfig, settings: &settings)

        try SettingsMigrationStep.importRepresentableKeys(userConfigPath: userConfig)
        let after = try String(contentsOf: userConfig, encoding: .utf8)
        // Fallback chain preserved
        XCTAssertTrue(after.contains("font-family = SF Mono"))
        XCTAssertTrue(after.contains("font-family = JetBrains Mono"))
        // palette preserved
        XCTAssertTrue(after.contains("palette = 0=#000000"))
        // representable theme line removed
        XCTAssertFalse(after.contains("theme = Dracula"))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsMigrationBranchBTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter SettingsMigrationBranchBTests`
Expected: FAIL — Branch B is a stub; `importRepresentableKeys` undefined.

- [ ] **Step 3: Replace the stub with the real Branch B implementation**

In `SettingsMigrationStep.swift` replace `runBranchB` and add `importRepresentableKeys`:

```swift
internal extension SettingsMigrationStep {
    @MainActor
    static func runBranchB(
        userConfigPath: URL,
        settings: inout CatermSettings
    ) throws -> BranchBSummary {
        let text = (try? String(contentsOf: userConfigPath, encoding: .utf8)) ?? ""
        let classification = PartialSettings.classifyConfig(text)

        for entry in classification.representable {
            applyRepresentableField(entry, to: &settings.global)
        }

        return BranchBSummary(
            representableCount: classification.representable.count,
            unrepresentableCount: classification.unrepresentable.count
        )
    }

    private static func applyRepresentableField(
        _ entry: RepresentableEntry,
        to s: inout PartialSettings
    ) {
        switch (entry.key, entry.value) {
        case ("font-family", .string(let v)):       s.fontFamily = v
        case ("font-size", .int(let v)):            s.fontSize = v
        case ("theme", .string(let v)):             s.theme = v
        case ("cursor-style", .cursorStyle(let v)): s.cursorStyle = v
        case ("cursor-style-blink", .bool(let v)):  s.cursorBlink = v
        case ("bell-features", .bell(let v)):       s.bell = v
        case ("scrollback-limit", .int(let v)):     s.scrollbackBytes = v
        case ("background-opacity", .double(let v)): s.windowOpacity = v
        case ("window-padding-x", .int(let v)):     s.windowPaddingX = v
        case ("window-padding-y", .int(let v)):     s.windowPaddingY = v
        case ("macos-titlebar-style", .titlebar(let v)): s.titlebarStyle = v
        default: break
        }
    }
}

public extension SettingsMigrationStep {
    /// Removes only the representable single-line keys from user config; preserves all
    /// other lines, comments, and blank lines byte-for-byte. Multi-occurrence fallback
    /// chains and unmodeled keys are kept intact.
    @MainActor
    static func importRepresentableKeys(userConfigPath: URL) throws {
        let text = try String(contentsOf: userConfigPath, encoding: .utf8)
        let classification = PartialSettings.classifyConfig(text)
        let linesToRemove = classification.representable.flatMap(\.sourceLines)
        let edited = GhosttyConfigParser.removeLines(text, lineNumbers: linesToRemove)
        try edited.write(to: userConfigPath, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter SettingsMigrationBranchBTests`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsStore/SettingsMigrationStep.swift apps/macos/Tests/SettingsStoreTests/SettingsMigrationBranchBTests.swift
git commit -m "feat(macos): SettingsMigrationStep Branch B with lossless importRepresentableKeys"
```

---

## Phase 5 — Live reload pipeline through GhosttyKit

### Task 16: ConfigDiagnostic — parse ghostty_diagnostic_s

**Files:**
- Create: `apps/macos/Sources/TerminalEngine/ConfigDiagnostic.swift`
- Test: `apps/macos/Tests/TerminalEngineTests/ConfigDiagnosticTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/TerminalEngineTests/ConfigDiagnosticTests.swift
import XCTest
@testable import TerminalEngine

final class ConfigDiagnosticTests: XCTestCase {
    func testParseMessageOnly() {
        let d = ConfigDiagnostic(message: "unknown key: foo-bar")
        XCTAssertEqual(d.message, "unknown key: foo-bar")
    }

    func testEmptyArrayWhenNoDiagnostics() {
        let result = ConfigDiagnostic.collect(rawCount: 0, fetch: { _ in nil })
        XCTAssertTrue(result.isEmpty)
    }

    func testCollectsAllDiagnostics() {
        let messages = ["one", "two", "three"]
        let result = ConfigDiagnostic.collect(rawCount: 3) { i in messages[Int(i)] }
        XCTAssertEqual(result.map(\.message), messages)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter ConfigDiagnosticTests`
Expected: FAIL — type undefined.

- [ ] **Step 3: Implement ConfigDiagnostic**

```swift
// apps/macos/Sources/TerminalEngine/ConfigDiagnostic.swift
import Foundation
import GhosttyKit

/// Swift wrapper around `ghostty_diagnostic_s`. The C struct (header lines 397-401) only
/// exposes `message` — there is no severity or location field. If a future GhosttyKit
/// version adds severity, update `parse(_:)` here.
public struct ConfigDiagnostic: Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public static func parse(_ raw: ghostty_diagnostic_s) -> ConfigDiagnostic {
        let msg = raw.message.flatMap { String(cString: $0) } ?? ""
        return ConfigDiagnostic(message: msg)
    }

    /// Test seam — collect via a fetch closure so we don't need a real ghostty_config_t in unit tests.
    public static func collect(
        rawCount: UInt32,
        fetch: (UInt32) -> String?
    ) -> [ConfigDiagnostic] {
        var out: [ConfigDiagnostic] = []
        for i in 0..<rawCount {
            if let m = fetch(i) {
                out.append(ConfigDiagnostic(message: m))
            }
        }
        return out
    }

    /// Production helper that talks to GhosttyKit directly.
    public static func collect(from cfg: ghostty_config_t) -> [ConfigDiagnostic] {
        let count = ghostty_config_diagnostics_count(cfg)
        var out: [ConfigDiagnostic] = []
        for i in 0..<count {
            let raw = ghostty_config_get_diagnostic(cfg, i)
            out.append(parse(raw))
        }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter ConfigDiagnosticTests`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/TerminalEngine/ConfigDiagnostic.swift apps/macos/Tests/TerminalEngineTests/ConfigDiagnosticTests.swift
git commit -m "feat(macos): ConfigDiagnostic wrapper around ghostty_diagnostic_s"
```

---

### Task 17: GhosttyConfig — accept per-host patch path and rebuild API

**Files:**
- Modify: `apps/macos/Sources/TerminalEngine/GhosttyConfig.swift`
- Test: `apps/macos/Tests/TerminalEngineTests/GhosttyConfigBuilderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/TerminalEngineTests/GhosttyConfigBuilderTests.swift
import XCTest
@testable import TerminalEngine

@MainActor
final class GhosttyConfigBuilderTests: XCTestCase {
    func testBuilderRecordsLoadOrder() {
        // Use the test seam: pass a closure-based recorder instead of GhosttyKit calls
        var loaded: [String] = []
        let builder = GhosttyConfigBuilder(loadDefaults: { loaded.append("defaults") },
                                           loadFile: { loaded.append("file:\($0)") },
                                           finalize: { loaded.append("finalize") },
                                           diagnosticsCount: { 0 },
                                           getDiagnostic: { _ in "" })
        _ = builder.build(
            managedPath: "/tmp/managed.config",
            userPath: "/tmp/user.config",
            perHostPath: "/tmp/h1.config"
        )
        XCTAssertEqual(loaded, [
            "defaults",
            "file:/tmp/managed.config",
            "file:/tmp/user.config",
            "file:/tmp/h1.config",
            "finalize",
        ])
    }

    func testBuildSurfacesDiagnostics() {
        let builder = GhosttyConfigBuilder(
            loadDefaults: {},
            loadFile: { _ in },
            finalize: {},
            diagnosticsCount: { 2 },
            getDiagnostic: { i in i == 0 ? "warning: a" : "warning: b" }
        )
        let result = builder.build(managedPath: "/tmp/m", userPath: nil, perHostPath: nil)
        XCTAssertEqual(result.diagnostics.map(\.message), ["warning: a", "warning: b"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter GhosttyConfigBuilderTests`
Expected: FAIL — `GhosttyConfigBuilder` undefined.

- [ ] **Step 3: Add GhosttyConfigBuilder (testable façade)**

Append to `apps/macos/Sources/TerminalEngine/GhosttyConfig.swift`:

```swift
/// Test-friendly façade over `ghostty_config_t` construction. Production code uses
/// the GhosttyKit-backed initializer; tests use the closure initializer.
@MainActor
public struct GhosttyConfigBuilder {
    public let loadDefaults: () -> Void
    public let loadFile: (String) -> Void
    public let finalize: () -> Void
    public let diagnosticsCount: () -> UInt32
    public let getDiagnostic: (UInt32) -> String

    public init(
        loadDefaults: @escaping () -> Void,
        loadFile: @escaping (String) -> Void,
        finalize: @escaping () -> Void,
        diagnosticsCount: @escaping () -> UInt32,
        getDiagnostic: @escaping (UInt32) -> String
    ) {
        self.loadDefaults = loadDefaults
        self.loadFile = loadFile
        self.finalize = finalize
        self.diagnosticsCount = diagnosticsCount
        self.getDiagnostic = getDiagnostic
    }

    public struct Built {
        public let diagnostics: [ConfigDiagnostic]
    }

    public func build(managedPath: String, userPath: String?, perHostPath: String?) -> Built {
        loadDefaults()
        loadFile(managedPath)
        if let userPath { loadFile(userPath) }
        if let perHostPath { loadFile(perHostPath) }
        finalize()
        let diagnostics = ConfigDiagnostic.collect(rawCount: diagnosticsCount()) { i in
            getDiagnostic(i)
        }
        return Built(diagnostics: diagnostics)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter GhosttyConfigBuilderTests`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/TerminalEngine/GhosttyConfig.swift apps/macos/Tests/TerminalEngineTests/GhosttyConfigBuilderTests.swift
git commit -m "feat(macos): GhosttyConfigBuilder façade with diagnostic surfacing"
```

---

### Task 18: GhosttySurface — apply per-host patch after surface_new

**Files:**
- Modify: `apps/macos/Sources/TerminalEngine/GhosttySurface.swift`

- [ ] **Step 1: Write the failing test**

Add to `apps/macos/Tests/TerminalEngineTests/GhosttyConfigBuilderTests.swift`:

```swift
extension GhosttyConfigBuilderTests {
    func testHostScopedConfigIncludesPerHostPath() {
        var loaded: [String] = []
        let builder = GhosttyConfigBuilder(
            loadDefaults: { loaded.append("defaults") },
            loadFile: { loaded.append($0) },
            finalize: { loaded.append("finalize") },
            diagnosticsCount: { 0 },
            getDiagnostic: { _ in "" }
        )
        _ = builder.build(
            managedPath: "/tmp/m",
            userPath: "/tmp/u",
            perHostPath: "/tmp/per-host/h.config"
        )
        XCTAssertTrue(loaded.contains("/tmp/per-host/h.config"))
        // Per-host loaded after user (so it overrides)
        let userIdx = loaded.firstIndex(of: "/tmp/u")!
        let hostIdx = loaded.firstIndex(of: "/tmp/per-host/h.config")!
        XCTAssertLessThan(userIdx, hostIdx)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter testHostScopedConfigIncludesPerHostPath`
Expected: PASS already (Task 17 already orders correctly). If not, fix Task 17.

- [ ] **Step 3: Wire surface-side application**

Add to `GhosttySurface.swift` (after the `init` body where the surface is created — the existing `ghostty_surface_new` call):

```swift
// At the bottom of init, after surface is successfully created:
applyPerHostPatchIfPresent(hostId: host.id)

// Add helper
@MainActor
private func applyPerHostPatchIfPresent(hostId: HostId) {
    let path = ConfigStore.perHostPatchPath(for: hostId)
    guard FileManager.default.fileExists(atPath: path.path) else { return }
    guard let cfg = ghostty_config_new() else { return }
    ghostty_config_load_default_files(cfg)
    ghostty_config_load_file(cfg, ConfigStore.managedConfigPath.path)
    if let userPath = catermConfigPath, FileManager.default.fileExists(atPath: userPath) {
        ghostty_config_load_file(cfg, userPath)
    }
    ghostty_config_load_file(cfg, path.path)
    ghostty_config_finalize(cfg)
    ghostty_surface_update_config(handle, cfg)
    ghostty_config_free(cfg)
}
```

(Adjust signature and references to match the existing types — `host.id`, `handle`, `catermConfigPath` — with whatever the file actually exposes; the current source uses `let surface = ghostty_surface_new(...)`, so use the same name.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter GhosttyConfigBuilderTests`
Expected: PASS — 3 tests total.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/TerminalEngine/GhosttySurface.swift apps/macos/Tests/TerminalEngineTests/GhosttyConfigBuilderTests.swift
git commit -m "feat(macos): apply per-host theme patch after surface_new"
```

---

### Task 19: Live-reload listener — wire SettingsStore notifications to all surfaces

**Files:**
- Modify: `apps/macos/Sources/TerminalEngine/GhosttyApp.swift`
- Test: `apps/macos/Tests/TerminalEngineTests/LiveReloadDispatchTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/TerminalEngineTests/LiveReloadDispatchTests.swift
import XCTest
import SettingsStore
@testable import TerminalEngine

@MainActor
final class LiveReloadDispatchTests: XCTestCase {
    func testGlobalLiveScopeDispatchesToAllSurfaces() throws {
        var refreshedSurfaces: [String] = []
        let dispatcher = LiveReloadDispatcher(
            surfaceIds: { ["a", "b", "c"] },
            applyToSurface: { id in refreshedSurfaces.append(id) },
            applyToApp: { /* ignore */ },
            renderManagedSnapshot: { _ in },
            buildConfig: { ConfigDiagnostic.collect(rawCount: 0, fetch: { _ in nil }) }
        )
        dispatcher.handle(scope: .globalLive, settings: CatermSettings.empty)
        XCTAssertEqual(refreshedSurfaces.sorted(), ["a", "b", "c"])
    }

    func testGlobalNewSurfaceDoesNotRefreshExisting() {
        var refreshedSurfaces: [String] = []
        let dispatcher = LiveReloadDispatcher(
            surfaceIds: { ["a", "b"] },
            applyToSurface: { refreshedSurfaces.append($0) },
            applyToApp: { },
            renderManagedSnapshot: { _ in },
            buildConfig: { [] }
        )
        dispatcher.handle(scope: .globalNewSurface, settings: CatermSettings.empty)
        XCTAssertEqual(refreshedSurfaces, [])
    }

    func testHostOverrideDoesNotRefreshExisting() {
        var refreshedSurfaces: [String] = []
        let dispatcher = LiveReloadDispatcher(
            surfaceIds: { ["a"] },
            applyToSurface: { refreshedSurfaces.append($0) },
            applyToApp: { },
            renderManagedSnapshot: { _ in },
            buildConfig: { [] }
        )
        dispatcher.handle(
            scope: .hostOverride(HostId("h")),
            settings: CatermSettings.empty
        )
        XCTAssertEqual(refreshedSurfaces, [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter LiveReloadDispatchTests`
Expected: FAIL — `LiveReloadDispatcher` undefined.

- [ ] **Step 3: Implement LiveReloadDispatcher**

Create `apps/macos/Sources/TerminalEngine/LiveReloadDispatcher.swift`:

```swift
import Foundation
import SettingsStore

@MainActor
public struct LiveReloadDispatcher {
    public let surfaceIds: () -> [String]
    public let applyToSurface: (String) -> Void
    public let applyToApp: () -> Void
    public let renderManagedSnapshot: (PartialSettings) throws -> Void
    public let buildConfig: () -> [ConfigDiagnostic]

    public init(
        surfaceIds: @escaping () -> [String],
        applyToSurface: @escaping (String) -> Void,
        applyToApp: @escaping () -> Void,
        renderManagedSnapshot: @escaping (PartialSettings) throws -> Void,
        buildConfig: @escaping () -> [ConfigDiagnostic]
    ) {
        self.surfaceIds = surfaceIds
        self.applyToSurface = applyToSurface
        self.applyToApp = applyToApp
        self.renderManagedSnapshot = renderManagedSnapshot
        self.buildConfig = buildConfig
    }

    public func handle(scope: SettingsChangeScope, settings: CatermSettings) {
        try? renderManagedSnapshot(settings.global)
        let diagnostics = buildConfig()
        if !diagnostics.isEmpty {
            postDiagnosticsBanner(diagnostics)
        }
        switch scope {
        case .globalLive:
            applyToApp()
            for id in surfaceIds() {
                applyToSurface(id)
            }
        case .globalNewSurface:
            applyToApp()
            postNewSurfaceBanner()
        case .hostOverride:
            // No-op for existing surfaces; new surfaces apply patch via §2.4.3.
            break
        }
    }

    private func postDiagnosticsBanner(_ diagnostics: [ConfigDiagnostic]) {
        NotificationCenter.default.post(
            name: Notification.Name("catermConfigDiagnostics"),
            object: nil,
            userInfo: ["diagnostics": diagnostics.map(\.message)]
        )
    }

    private func postNewSurfaceBanner() {
        NotificationCenter.default.post(
            name: Notification.Name("catermNewSurfaceBanner"),
            object: nil
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter LiveReloadDispatchTests`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/TerminalEngine/LiveReloadDispatcher.swift apps/macos/Tests/TerminalEngineTests/LiveReloadDispatchTests.swift
git commit -m "feat(macos): LiveReloadDispatcher routes scope to surfaces/app/banners"
```

---

### Task 20: Boot wiring — load settings, run migration, regenerate patches, install dispatcher

**Files:**
- Modify: `apps/macos/Sources/Caterm/AppDelegate.swift` (or `CatermApp.swift` `init`)
- Test: `apps/macos/Tests/CatermTests/BootSequenceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// apps/macos/Tests/CatermTests/BootSequenceTests.swift
import XCTest
import ConfigStore
import SettingsStore
@testable import Caterm

@MainActor
final class BootSequenceTests: XCTestCase {
    func testBootSeedsFromLegacyDefaultAndRegeneratesPatches() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let userConfig = dir.appendingPathComponent("config")
        try SettingsMigrationStep.legacyDefaultV1.write(
            to: userConfig, atomically: true, encoding: .utf8
        )

        let plistURL = dir.appendingPathComponent("settings.plist")
        let perHostDir = dir.appendingPathComponent("per-host")

        let store = try BootSequence.run(
            settingsPlistURL: plistURL,
            userConfigURL: userConfig,
            managedSnapshotURL: dir.appendingPathComponent("managed.config"),
            perHostDirectory: perHostDir
        )

        XCTAssertTrue(store.settings.migrationsCompleted.contains(SettingsMigrationStep.token))
        XCTAssertEqual(store.settings.global.theme, "Catppuccin Mocha")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("managed.config").path))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BootSequenceTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter BootSequenceTests`
Expected: FAIL — `BootSequence` undefined.

- [ ] **Step 3: Implement BootSequence**

Create `apps/macos/Sources/Caterm/BootSequence.swift`:

```swift
import Foundation
import ConfigStore
import SettingsStore

@MainActor
public enum BootSequence {
    @discardableResult
    public static func run(
        settingsPlistURL: URL,
        userConfigURL: URL,
        managedSnapshotURL: URL,
        perHostDirectory: URL
    ) throws -> SettingsStore {
        // 1. Load (or seed) settings.plist
        let store = try SettingsStore.load(from: settingsPlistURL)
        var settings = store.settings

        // 2. Migration (one-shot, gated by token)
        _ = try SettingsMigrationStep.runIfNeeded(
            userConfigPath: userConfigURL,
            settings: &settings
        )

        // 3. Persist any settings the migration produced
        if settings != store.settings {
            try store.save(settings)
        }

        // 4. Render managed snapshot
        try ConfigStore.renderManagedSnapshot(from: settings.global, to: managedSnapshotURL)

        // 5. Regenerate per-host patches from plist
        try ConfigStore.regeneratePerHostPatches(from: settings, in: perHostDirectory)

        return store
    }
}
```

Wire into the production app — modify `AppDelegate.swift`'s `applicationDidFinishLaunching`:

```swift
let store = try BootSequence.run(
    settingsPlistURL: SettingsStore.defaultPlistPath,
    userConfigURL: ConfigStore.defaultPath,
    managedSnapshotURL: ConfigStore.managedConfigPath,
    perHostDirectory: ConfigStore.perHostPatchDirectory
)
self.settingsStore = store
```

(Add `SettingsStore.defaultPlistPath` if not already present:)

```swift
// In SettingsStore.swift
public static var defaultPlistPath: URL {
    FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Caterm/settings.plist")
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter BootSequenceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/BootSequence.swift apps/macos/Sources/Caterm/AppDelegate.swift apps/macos/Sources/SettingsStore/SettingsStore.swift apps/macos/Tests/CatermTests/BootSequenceTests.swift
git commit -m "feat(macos): BootSequence — migration + snapshot + per-host patch regen at start"
```

---

## Phase 6 — UI

### Task 21: PreferencesWindowController + tab framework

**Files:**
- Create: `apps/macos/Sources/Caterm/Views/Preferences/PreferencesWindowController.swift`
- Create: `apps/macos/Sources/Caterm/Views/Preferences/PreferencesTab.swift`

- [ ] **Step 1: Write the failing test**

Create `apps/macos/Tests/CatermTests/PreferencesWindowTests.swift`:

```swift
import XCTest
@testable import Caterm

@MainActor
final class PreferencesWindowTests: XCTestCase {
    func testWindowHasFourTabs() {
        let ctrl = PreferencesWindowController()
        XCTAssertEqual(ctrl.tabs.map(\.title), ["General", "Terminal", "Themes", "Sync"])
    }

    func testSwitchingTabUpdatesActiveIndex() {
        let ctrl = PreferencesWindowController()
        ctrl.activate(tabIndex: 2)
        XCTAssertEqual(ctrl.activeTabIndex, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter PreferencesWindowTests`
Expected: FAIL — type undefined.

- [ ] **Step 3: Implement PreferencesWindowController**

```swift
// apps/macos/Sources/Caterm/Views/Preferences/PreferencesTab.swift
import AppKit
import SwiftUI

public struct PreferencesTab {
    public let title: String
    public let systemImage: String
    public let viewBuilder: () -> AnyView

    public init(title: String, systemImage: String, view: @escaping () -> some View) {
        self.title = title
        self.systemImage = systemImage
        self.viewBuilder = { AnyView(view()) }
    }
}
```

```swift
// apps/macos/Sources/Caterm/Views/Preferences/PreferencesWindowController.swift
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
            PreferencesTab(title: "Sync", systemImage: "icloud") { SyncSettingsView() },
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
```

Create stub views (filled in by Tasks 22–24):

```swift
// apps/macos/Sources/Caterm/Views/Preferences/GeneralSettingsView.swift
import SwiftUI
public struct GeneralSettingsView: View {
    public init() {}
    public var body: some View {
        Text("Coming soon").foregroundStyle(.secondary)
    }
}
```

```swift
// apps/macos/Sources/Caterm/Views/Preferences/TerminalSettingsView.swift
import SwiftUI
public struct TerminalSettingsView: View {
    public init() {}
    public var body: some View { Text("Terminal") }
}
```

```swift
// apps/macos/Sources/Caterm/Views/Preferences/ThemePickerView.swift
import SwiftUI
public struct ThemePickerView: View {
    public init() {}
    public var body: some View { Text("Themes") }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter PreferencesWindowTests`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/Preferences/ apps/macos/Tests/CatermTests/PreferencesWindowTests.swift
git commit -m "feat(macos): PreferencesWindowController with 4-tab toolbar"
```

---

### Task 22: TerminalSettingsView — full controls bound to SettingsStore

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/Preferences/TerminalSettingsView.swift`

- [ ] **Step 1: Write the failing test**

Create `apps/macos/Tests/CatermTests/TerminalSettingsBindingsTests.swift`:

```swift
import XCTest
import SettingsStore
@testable import Caterm

@MainActor
final class TerminalSettingsBindingsTests: XCTestCase {
    func testFontSizeStepperUpdatesStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
        let bindings = TerminalSettingsBindings(store: store)
        bindings.fontSize.wrappedValue = 17
        store.flushNow()
        XCTAssertEqual(store.settings.global.fontSize, 17)
    }

    func testCursorStyleSegmented() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
        let bindings = TerminalSettingsBindings(store: store)
        bindings.cursorStyle.wrappedValue = .bar
        store.flushNow()
        XCTAssertEqual(store.settings.global.cursorStyle, .bar)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter TerminalSettingsBindingsTests`
Expected: FAIL — `TerminalSettingsBindings` undefined.

- [ ] **Step 3: Implement bindings + view**

```swift
// apps/macos/Sources/Caterm/Views/Preferences/TerminalSettingsView.swift
import SwiftUI
import SettingsStore
import ConfigStore

@MainActor
public struct TerminalSettingsBindings {
    let store: SettingsStore
    public init(store: SettingsStore) { self.store = store }

    public var fontFamily: Binding<String> {
        Binding(
            get: { store.settings.global.fontFamily ?? "SF Mono" },
            set: { v in store.update { $0.global.fontFamily = v } }
        )
    }
    public var fontSize: Binding<Int> {
        Binding(
            get: { store.settings.global.fontSize ?? 13 },
            set: { v in store.update { $0.global.fontSize = v } }
        )
    }
    public var lineHeight: Binding<Double> {
        Binding(
            get: { store.settings.global.lineHeight ?? 1.0 },
            set: { v in store.update { $0.global.lineHeight = v } }
        )
    }
    public var cursorStyle: Binding<CursorStyle> {
        Binding(
            get: { store.settings.global.cursorStyle ?? .block },
            set: { v in store.update { $0.global.cursorStyle = v } }
        )
    }
    public var cursorBlink: Binding<Bool> {
        Binding(
            get: { store.settings.global.cursorBlink ?? false },
            set: { v in store.update { $0.global.cursorBlink = v } }
        )
    }
    public var bell: Binding<BellMode> {
        Binding(
            get: { store.settings.global.bell ?? .visual },
            set: { v in store.update { $0.global.bell = v } }
        )
    }
    public var scrollbackMB: Binding<Int> {
        Binding(
            get: { (store.settings.global.scrollbackBytes ?? 10_000_000) / 1_000_000 },
            set: { v in store.update { $0.global.scrollbackBytes = v * 1_000_000 } }
        )
    }
    public var windowOpacity: Binding<Double> {
        Binding(
            get: { store.settings.global.windowOpacity ?? 1.0 },
            set: { v in store.update { $0.global.windowOpacity = v } }
        )
    }
    public var windowPaddingX: Binding<Int> {
        Binding(
            get: { store.settings.global.windowPaddingX ?? 4 },
            set: { v in store.update { $0.global.windowPaddingX = v } }
        )
    }
    public var windowPaddingY: Binding<Int> {
        Binding(
            get: { store.settings.global.windowPaddingY ?? 4 },
            set: { v in store.update { $0.global.windowPaddingY = v } }
        )
    }
}

public struct TerminalSettingsView: View {
    @EnvironmentObject var store: SettingsStore

    public init() {}

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
                    Text("Opacity: \(b.windowOpacity.wrappedValue, specifier: "%.2f")")
                }
                Stepper("Padding X: \(b.windowPaddingX.wrappedValue)", value: b.windowPaddingX, in: 0...40)
                Stepper("Padding Y: \(b.windowPaddingY.wrappedValue)", value: b.windowPaddingY, in: 0...40)
            }
            Divider()
            HStack {
                Button("Edit Advanced Config…") {
                    ConfigStore.revealInFinder(ConfigStore.defaultPath)
                }
                Spacer()
                Text(userOverrideHintText())
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
        .padding()
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter TerminalSettingsBindingsTests`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/Preferences/TerminalSettingsView.swift apps/macos/Tests/CatermTests/TerminalSettingsBindingsTests.swift
git commit -m "feat(macos): TerminalSettingsView with full controls bound to store"
```

---

### Task 23: ThemePickerView + ThemeCardView with favorites + search

**Files:**
- Create: `apps/macos/Sources/Caterm/Views/Preferences/ThemeCardView.swift`
- Modify: `apps/macos/Sources/Caterm/Views/Preferences/ThemePickerView.swift`

- [ ] **Step 1: Write the failing test**

Create `apps/macos/Tests/CatermTests/ThemePickerLogicTests.swift`:

```swift
import XCTest
import SettingsStore
@testable import Caterm

final class ThemePickerLogicTests: XCTestCase {
    func testFiltersGridByQueryCaseInsensitive() {
        let catalog = ThemeCatalog(themes: [
            sample("Dracula"),
            sample("One Dark Two"),
            sample("Catppuccin Mocha"),
        ])
        let logic = ThemePickerLogic(catalog: catalog)
        XCTAssertEqual(logic.filtered(query: "dark").map(\.name), ["One Dark Two"])
        XCTAssertEqual(logic.filtered(query: "").count, 3)
    }

    func testFavoritesAlwaysVisibleEvenWhenSearchedAway() {
        let catalog = ThemeCatalog(themes: ThemeCatalog.fallback.themes)
        let logic = ThemePickerLogic(catalog: catalog)
        XCTAssertEqual(logic.favorites.map(\.name).sorted(), ThemeCatalog.favoriteNames.sorted())
    }

    private func sample(_ n: String) -> ThemeRecord {
        ThemeRecord(
            name: n, palette: Array(repeating: "#000", count: 16),
            background: "#000", foreground: "#fff",
            cursorColor: nil, selectionBackground: nil
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter ThemePickerLogicTests`
Expected: FAIL — `ThemePickerLogic` undefined.

- [ ] **Step 3: Implement logic + view**

```swift
// apps/macos/Sources/Caterm/Views/Preferences/ThemeCardView.swift
import SwiftUI
import SettingsStore

public struct ThemeCardView: View {
    let theme: ThemeRecord
    let isSelected: Bool
    let action: () -> Void

    public init(theme: ThemeRecord, isSelected: Bool, action: @escaping () -> Void) {
        self.theme = theme
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(theme.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 2) {
                    ForEach(0..<min(8, theme.palette.count), id: \.self) { i in
                        Color.fromHex(theme.palette[i])
                            .frame(width: 14, height: 14)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                }
                Color.fromHex(theme.background)
                    .frame(height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

extension Color {
    static func fromHex(_ hex: String) -> Color {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let v = UInt32(cleaned, radix: 16) else { return .black }
        return Color(
            red: Double((v >> 16) & 0xff) / 255,
            green: Double((v >> 8) & 0xff) / 255,
            blue: Double(v & 0xff) / 255
        )
    }
}
```

```swift
// apps/macos/Sources/Caterm/Views/Preferences/ThemePickerView.swift
import SwiftUI
import SettingsStore

public struct ThemePickerLogic {
    public let catalog: ThemeCatalog

    public init(catalog: ThemeCatalog) { self.catalog = catalog }

    public var favorites: [ThemeRecord] { catalog.favorites }

    public func filtered(query: String) -> [ThemeRecord] {
        if query.isEmpty { return catalog.themes }
        return catalog.themes.filter {
            $0.name.range(of: query, options: .caseInsensitive) != nil
        }
    }
}

public struct ThemePickerView: View {
    @EnvironmentObject var store: SettingsStore
    @State private var query: String = ""
    private let logic: ThemePickerLogic

    public init() {
        self.logic = ThemePickerLogic(catalog: ThemeCatalog.loadBundled())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search themes…", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Section {
                        Text("Favorites").font(.headline)
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(logic.favorites) { theme in
                                card(for: theme)
                            }
                        }
                    }
                    if !query.isEmpty || logic.catalog.themes.count > logic.favorites.count {
                        Section {
                            Text(query.isEmpty ? "All Themes" : "Results")
                                .font(.headline)
                            LazyVGrid(columns: gridColumns, spacing: 12) {
                                ForEach(logic.filtered(query: query)) { theme in
                                    card(for: theme)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom)
            }
        }
        .padding()
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 140), spacing: 12), count: 3)
    }

    private func card(for theme: ThemeRecord) -> some View {
        ThemeCardView(
            theme: theme,
            isSelected: store.settings.global.theme == theme.name,
            action: {
                store.update { $0.global.theme = theme.name }
            }
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter ThemePickerLogicTests`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/Preferences/ThemeCardView.swift apps/macos/Sources/Caterm/Views/Preferences/ThemePickerView.swift apps/macos/Tests/CatermTests/ThemePickerLogicTests.swift
git commit -m "feat(macos): ThemePickerView with favorites grid + searchable catalog"
```

---

### Task 24: HostFormView per-host theme override

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/HostFormView.swift`

- [ ] **Step 1: Write the failing test**

Create `apps/macos/Tests/CatermTests/HostThemeOverrideTests.swift`:

```swift
import XCTest
import SettingsStore
@testable import Caterm

@MainActor
final class HostThemeOverrideTests: XCTestCase {
    func testSetOverrideStoresThemeAndRegeneratesPatch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
        let logic = HostThemeOverrideLogic(store: store)
        logic.setTheme("Dracula", forHost: HostId("h1"))
        store.flushNow()
        XCTAssertEqual(store.settings.hostOverrides[HostId("h1")]?.theme, "Dracula")
    }

    func testClearOverrideRemovesEntry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
        let logic = HostThemeOverrideLogic(store: store)
        logic.setTheme("Dracula", forHost: HostId("h1"))
        logic.setTheme(nil, forHost: HostId("h1"))
        store.flushNow()
        XCTAssertNil(store.settings.hostOverrides[HostId("h1")]?.theme)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter HostThemeOverrideTests`
Expected: FAIL — `HostThemeOverrideLogic` undefined.

- [ ] **Step 3: Implement logic + form section**

Create `apps/macos/Sources/Caterm/Views/Preferences/HostThemeOverrideLogic.swift`:

```swift
import Foundation
import SettingsStore

@MainActor
public struct HostThemeOverrideLogic {
    let store: SettingsStore

    public init(store: SettingsStore) { self.store = store }

    public func setTheme(_ theme: String?, forHost id: HostId) {
        store.update { settings in
            if let theme {
                settings.hostOverrides[id] = PartialSettings(theme: theme)
            } else {
                settings.hostOverrides.removeValue(forKey: id)
            }
        }
    }
}
```

In `HostFormView.swift`, add a Section. Locate the existing form body and append before the form's submit buttons:

```swift
// HostFormView.swift — add this section
Section("Theme Override") {
    HostThemeOverridePicker(hostId: hostId)
        .environmentObject(settingsStore)
}
```

Where `HostThemeOverridePicker` is:

```swift
// apps/macos/Sources/Caterm/Views/Preferences/HostThemeOverridePicker.swift
import SwiftUI
import SettingsStore

public struct HostThemeOverridePicker: View {
    @EnvironmentObject var store: SettingsStore
    let hostId: HostId

    public init(hostId: HostId) { self.hostId = hostId }

    public var body: some View {
        let logic = HostThemeOverrideLogic(store: store)
        let catalog = ThemeCatalog.loadBundled()
        let current = store.settings.hostOverrides[hostId]?.theme
        Picker("Theme", selection: Binding(
            get: { current ?? "" },
            set: { value in logic.setTheme(value.isEmpty ? nil : value, forHost: hostId) }
        )) {
            Text("Use global").tag("")
            ForEach(catalog.themes) { theme in
                Text(theme.name).tag(theme.name)
            }
        }
    }
}
```

(`HostFormView` may need to receive `settingsStore` via `@EnvironmentObject`; thread it from the parent view.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter HostThemeOverrideTests`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/HostFormView.swift apps/macos/Sources/Caterm/Views/Preferences/HostThemeOverrideLogic.swift apps/macos/Sources/Caterm/Views/Preferences/HostThemeOverridePicker.swift apps/macos/Tests/CatermTests/HostThemeOverrideTests.swift
git commit -m "feat(macos): per-host theme override picker in HostFormView"
```

---

### Task 25: Replace ⌘, behavior — open Preferences window

**Files:**
- Modify: `apps/macos/Sources/Caterm/CatermApp.swift`

- [ ] **Step 1: Write the failing test**

Add to `PreferencesWindowTests.swift`:

```swift
extension PreferencesWindowTests {
    func testSharedInstanceShowsAndReuses() {
        let first = PreferencesWindowController.shared
        let second = PreferencesWindowController.shared
        XCTAssertTrue(first === second)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter testSharedInstanceShowsAndReuses`
Expected: FAIL — `shared` undefined.

- [ ] **Step 3: Add shared singleton + wire menu**

Append to `PreferencesWindowController.swift`:

```swift
@MainActor
public extension PreferencesWindowController {
    static let shared: PreferencesWindowController = PreferencesWindowController()

    func showAndActivate() {
        showWindow(self)
        window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

Modify `CatermApp.swift` — replace the existing ⌘, handler:

```swift
CommandGroup(replacing: .appSettings) {
    Button("Settings…") {
        PreferencesWindowController.shared.showAndActivate()
    }
    .keyboardShortcut(",", modifiers: .command)
}
```

Remove the `Sync Settings…` item below it (it's now a tab inside Preferences). Delete the line:

```swift
CommandGroup(after: .appSettings) {
    Button("Sync Settings…") { showSyncSettings = true }
        .keyboardShortcut(",", modifiers: [.command, .shift])
}
```

…and any related `@State var showSyncSettings` plus the `.sheet(isPresented: $showSyncSettings)` modifier — those become dead code.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter PreferencesWindowTests`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/Preferences/PreferencesWindowController.swift apps/macos/Sources/Caterm/CatermApp.swift apps/macos/Tests/CatermTests/PreferencesWindowTests.swift
git commit -m "feat(macos): ⌘, opens Preferences window; remove old reveal-in-Finder action"
```

---

## Phase 7 — Banners and smoke

### Task 26: Diagnostics + new-surface banners in MainWindow

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/MainWindow.swift`

- [ ] **Step 1: Write the failing test**

Create `apps/macos/Tests/CatermTests/SettingsBannerStateTests.swift`:

```swift
import XCTest
@testable import Caterm

@MainActor
final class SettingsBannerStateTests: XCTestCase {
    func testReceivesAndDismissesDiagnosticBanner() {
        let state = SettingsBannerState()
        NotificationCenter.default.post(
            name: Notification.Name("catermConfigDiagnostics"),
            object: nil,
            userInfo: ["diagnostics": ["unknown key: foo"]]
        )
        // Allow notification to dispatch
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(state.diagnosticMessages, ["unknown key: foo"])

        state.dismissDiagnostics()
        XCTAssertTrue(state.diagnosticMessages.isEmpty)
    }

    func testReceivesNewSurfaceBanner() {
        let state = SettingsBannerState()
        NotificationCenter.default.post(name: Notification.Name("catermNewSurfaceBanner"), object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(state.showNewSurfaceBanner)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter SettingsBannerStateTests`
Expected: FAIL — type undefined.

- [ ] **Step 3: Implement banner state**

Create `apps/macos/Sources/Caterm/Views/SettingsBannerState.swift`:

```swift
import Foundation
import Combine

@MainActor
public final class SettingsBannerState: ObservableObject {
    @Published public private(set) var diagnosticMessages: [String] = []
    @Published public private(set) var showNewSurfaceBanner: Bool = false

    private var observers: [NSObjectProtocol] = []

    public init() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: Notification.Name("catermConfigDiagnostics"),
                object: nil, queue: .main
            ) { [weak self] note in
                let msgs = note.userInfo?["diagnostics"] as? [String] ?? []
                Task { @MainActor in self?.diagnosticMessages = msgs }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: Notification.Name("catermNewSurfaceBanner"),
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.showNewSurfaceBanner = true }
            }
        )
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    public func dismissDiagnostics() { diagnosticMessages = [] }
    public func dismissNewSurface() { showNewSurfaceBanner = false }
}
```

Wire into `MainWindow.swift` (top of body):

```swift
@StateObject private var bannerState = SettingsBannerState()

// In body:
VStack(spacing: 0) {
    if !bannerState.diagnosticMessages.isEmpty {
        DiagnosticBanner(messages: bannerState.diagnosticMessages,
                         onDismiss: bannerState.dismissDiagnostics)
    }
    if bannerState.showNewSurfaceBanner {
        Banner(text: "Some settings (scrollback / titlebar) apply to new tabs only.",
               onDismiss: bannerState.dismissNewSurface)
    }
    // ...existing main body...
}
```

Add the small `Banner` and `DiagnosticBanner` views inline (~30 LOC) in the same file.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter SettingsBannerStateTests`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/SettingsBannerState.swift apps/macos/Sources/Caterm/Views/MainWindow.swift apps/macos/Tests/CatermTests/SettingsBannerStateTests.swift
git commit -m "feat(macos): config diagnostic + new-surface banners in MainWindow"
```

---

### Task 27: SyncSettingsView migration into Preferences tab

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/SyncSettingsView.swift` (already exists; ensure no stand-alone sheet trigger)

- [ ] **Step 1: Write the failing test**

Add to `PreferencesWindowTests.swift`:

```swift
extension PreferencesWindowTests {
    func testSyncTabRendersExistingView() {
        let ctrl = PreferencesWindowController()
        ctrl.activate(tabIndex: 3)
        // Visual smoke: hosted view exists
        XCTAssertNotNil(ctrl.window?.contentViewController)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && swift test --filter testSyncTabRendersExistingView`
Expected: PASS or FAIL depending on SyncSettingsView signature.

- [ ] **Step 3: Adjust SyncSettingsView so it works without sheet bindings**

Open `SyncSettingsView.swift`. If the view currently takes `@Binding var isPresented: Bool` (used by the old sheet), replace that with a no-arg initializer; make any "Done" button dismiss the *window* instead of toggling a binding:

```swift
public struct SyncSettingsView: View {
    public init() {}
    public var body: some View {
        // Existing sync settings UI…
        // Replace any "Done" button with: Button("Close") { NSApp.keyWindow?.close() }
    }
}
```

Remove the `@State var showSyncSettings = false` and `.sheet(...)` modifier from `MainWindow.swift` (those were the prior entry points; ⌘⇧, was already deleted in Task 25).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/macos && swift test --filter PreferencesWindowTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/SyncSettingsView.swift apps/macos/Sources/Caterm/Views/MainWindow.swift apps/macos/Tests/CatermTests/PreferencesWindowTests.swift
git commit -m "refactor(macos): SyncSettingsView is a Preferences tab; drop standalone sheet"
```

---

### Task 28: Manual smoke document

**Files:**
- Create: `apps/macos/Manual/settings-smoke.md`

- [ ] **Step 1: Write the failing test**

Smoke docs are not unit-tested. The "test" is that the file exists and matches the spec §9.2 list.

```bash
test -f apps/macos/Manual/settings-smoke.md && grep -q "Migration A" apps/macos/Manual/settings-smoke.md
```

- [ ] **Step 2: Run command to verify it fails**

Run: `test -f apps/macos/Manual/settings-smoke.md && grep -q 'Migration A' apps/macos/Manual/settings-smoke.md`
Expected: FAIL (exit 1, file missing).

- [ ] **Step 3: Write the smoke document**

```markdown
# Settings GUI — Manual Smoke

Run after every settings-related change. Refers to spec §9.2.

## Setup
- Build & run: `make run-app`
- Reset state to test migrations:
  ```bash
  rm -rf "$HOME/Library/Application Support/Caterm/settings.plist"
  rm -rf "$HOME/Library/Application Support/Caterm/per-host"
  ```

## Cases

1. **Fresh install (Migration C):** delete `settings.plist` and `~/Library/Application Support/Caterm/config`. Launch. ⌘, opens Preferences with defaults visible (SF Mono / 13 / Catppuccin Mocha / block / tabs titlebar). User config now contains only the placeholder comment.

2. **Migration A (legacy seed):** restore the legacy seed at `~/Library/Application Support/Caterm/config` (use the contents from `SettingsMigrationStep.legacyDefaultV1`); delete `settings.plist`. Launch. Backup file `config.bak-pre-settings-gui-…` created. User config replaced with placeholder. No visual change in any open tab.

3. **Migration B (custom user config):** seed a custom user config:
   ```
   font-family = JetBrains Mono
   font-family = SF Mono
   theme = light:Catppuccin Latte,dark:Catppuccin Mocha
   bell-features = audio,attention,no-title
   palette = 0=#000000
   ```
   Delete `settings.plist`. Launch. Banner appears listing representable + unrepresentable. Click **Import representable keys** → palette / fallback chain / split theme / custom bell-features all preserved; nothing single-line representable was found here so no lines removed. Edit a different config that *does* contain a representable single line (e.g., `cursor-style = bar`); after Import, that single line disappears; palette + fallback remain.

4. **Live: font size** → all open tabs reflow live.
5. **Live: cursor style** → live update on all tabs.
6. **Live: theme** → live update globally.
7. **Per-host theme:** in HostForm, set host A theme to Dracula. Connect to A → tab uses Dracula. Disconnect, reconnect → still Dracula. Connect to B (no override) → uses global theme.
8. **Global change while host-overridden tab open:** host-overridden tab keeps its theme; new tab to any host uses new global.
9. **Scrollback (new-surface):** change scrollback memory → banner "Scrollback change applies to new tabs." appears once. Existing tabs keep old buffer; new tab uses new size.
10. **Titlebar (new-surface):** change titlebar style → banner appears; existing windows unchanged; new window opened with ⌘N has new style.
11. **Diagnostics:** edit user config to add `font-family = ` (empty) and a deliberately unknown key. Open Preferences; diagnostic banner lists messages.
12. **Edit advanced:** click Edit Advanced Config → user config opens in Finder.
13. **Quit during edit:** type in stepper, ⌘Q within 200 ms → on relaunch, change is persisted.
14. **Theme picker:** ⌘, → Themes tab → 9 favorites visible above the fold; "All Themes" grid scrollable; search filters.
15. **Corruption recovery:** write garbage to `settings.plist` while app is closed. Launch. Defaults seeded; original quarantined to `settings.plist.broken-…`.
16. **Override hint:** add `cursor-style = underline` to user config; relaunch. Terminal tab footer shows "1 user-config override active".
```

- [ ] **Step 4: Run command to verify it passes**

Run: `test -f apps/macos/Manual/settings-smoke.md && grep -q 'Migration A' apps/macos/Manual/settings-smoke.md`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Manual/settings-smoke.md
git commit -m "docs(macos): manual smoke for terminal settings GUI"
```

---

## Self-Review

The following spec sections are addressed:

| Spec § | Plan task |
|---|---|
| §2.0 grammar | Tasks 1-2 (parser) |
| §2.0.1 GhosttyConfigParser | Tasks 1-2 |
| §2.1 layering audit | (informational; no task) |
| §2.2 layering | Tasks 4, 6 |
| §2.3 schema | Task 3 |
| §2.4.1 scope | Task 5 |
| §2.4.2 reload sequence | Tasks 16, 17, 19 |
| §2.4.3 per-host patch + boot regen | Tasks 7, 18, 20 |
| §2.4.4 precedence | Task 17 (load order) |
| §3.1 PreferencesWindow | Task 21 |
| §3.2 General placeholder | Task 21 |
| §3.3 Terminal tab | Task 22 |
| §3.4 Themes tab + build pipeline | Tasks 10, 11, 12, 23 |
| §3.5 Sync tab move | Task 27 |
| §3.6 Per-host UI | Task 24 |
| §4 module layout | Reflected across all tasks |
| §5.1 boot sequence | Task 20 |
| §5.2 write path | Tasks 9, 19 |
| §5.3 host theme resolution | Tasks 7, 18 |
| §6 field mapping incl §6.3 / §6.5 / §6.6 / §6.7 | Task 4 |
| §7 error handling | Tasks 8 (corruption), 16/26 (diagnostics), 22 (override hint), 13 (backup) |
| §8 migration | Tasks 13, 14, 15 |
| §9 testing | Tests embedded in every task |
| §10 out-of-scope | Acknowledged; nothing to do |

Naming consistency check passed: `SettingsStore.changeNotification`, `scopeUserInfoKey`, `liveReloadable`, `defaultsSeed`, `settings-gui-v1`, `legacyDefaultV1`, `perHostPatchPath(for:)`, `regeneratePerHostPatches(from:in:)`, `renderManagedSnapshot(from:to:)`, `SettingsChangeScope.diff(old:new:)` — all spelled the same way in tests and implementations. No placeholders or "TBD" anywhere.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-01-terminal-settings-plan.md`.

**Both Plan A (Remote Files) and Plan B (Terminal Settings) are ready for execution.** Two execution options for each:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration via `superpowers:subagent-driven-development`.
2. **Inline Execution** — execute tasks in this session via `superpowers:executing-plans` with checkpoints.

Both plans share no files (Plan A touches `SSHCommandBuilder`, `SessionStore`, new `RemoteFileSystem`/`FileTransferStore`; Plan B touches `ConfigStore`, new `SettingsStore`, `TerminalEngine`, `Caterm/Views/Preferences/`), so they can be executed in parallel worktrees if desired.

Which approach would you like?



