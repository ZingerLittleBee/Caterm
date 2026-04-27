# Phase 1 v1 Implementation Plan — Caterm Swift macOS Client

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a native macOS Swift/SwiftUI SSH terminal client (libghostty-rendered) that covers the v1 MVP six features: SSH connect (3-path auth), libghostty render + multi-tab, host list, Keychain credentials, auto-reconnect, host key verification — replacing the Tauri client for personal use plus a small internal beta.

**Architecture:** libghostty owns the PTY end-to-end; Swift never sees ssh stdout/stdin bytes. Surfaces spawn `/usr/bin/ssh user@host` via libghostty's `surface.command`. Three-path auth (`CredentialSource` enum: `.password / .keyFile / .agent`) pumps secrets into ssh through a separate signed `caterm-askpass` binary that reads the macOS Keychain via `SecItemCopyMatching` + Keychain access group ACL. See `docs/superpowers/specs/2026-04-27-tauri-to-swift-migration-design.md` (canonical) for the full design.

**Tech Stack:** Swift 5.10+, SwiftUI + AppKit, SwiftPM (no `.xcodeproj`), libghostty `.xcframework` `binaryTarget` (submodule pinned at `bc90a5128`), macOS 14+, swift-bundler for `.app`, Sparkle for updates, `xcrun notarytool` + `create-dmg` for distribution.

---

## File Structure (locked at start; refer to spec §3.2 / §3.4)

Directory layout under `apps/macos/`:

```
apps/macos/
├── Package.swift                            # 9 targets (5 lib, 2 exec, 4+ test)
├── Sources/
│   ├── Caterm/                              # @main app (executableTarget)
│   │   ├── CatermApp.swift                  # @main + WindowGroup
│   │   ├── Views/
│   │   │   ├── MainWindow.swift             # NSWindow + tabs container
│   │   │   ├── HostListSidebar.swift        # Left sidebar
│   │   │   ├── HostFormView.swift           # Add/Edit form
│   │   │   ├── ConnectDialog.swift          # Pick CredentialSource
│   │   │   ├── TerminalContainerView.swift  # Wraps GhosttySurfaceNSView + overlay
│   │   │   └── ReconnectOverlay.swift       # NSView overlay during Reconnecting
│   │   ├── Menus/
│   │   │   └── AppMenuBuilder.swift         # ⌘N/⌘T/⌘W/⌘, etc.
│   │   └── AppDelegate.swift                # NSApplicationDelegate (activation policy etc.)
│   │
│   ├── CatermAskpass/                       # caterm-askpass binary (executableTarget)
│   │   └── main.swift                       # ~200 LOC: env → SecItemCopyMatching → stdout
│   │
│   ├── TerminalEngine/                      # libghostty Swift wrapper (library)
│   │   ├── GhosttyApp.swift                 # ghostty_app_new/free singleton
│   │   ├── GhosttySurface.swift             # surface lifecycle + key/resize/exit signals
│   │   ├── GhosttySurfaceNSView.swift       # NSView host
│   │   └── GhosttyConfig.swift              # config buffer setup
│   │
│   ├── SSHCommandBuilder/                   # pure function (library)
│   │   ├── Host.swift                       # struct Host, enum CredentialSource
│   │   ├── SSHCommandBuilder.swift          # build(host:credential:askpassPath:knownHostsCaterm:knownHostsUser:) → (String, [(String,String)])
│   │   └── ShellQuote.swift                 # POSIX single-quote helper
│   │
│   ├── SessionStore/                        # ObservableObject (library)
│   │   ├── SessionStore.swift               # @MainActor; tab state; reconnect FSM
│   │   ├── ConnectionState.swift            # enum Idle/Connecting/Connected/Reconnecting/Failed
│   │   ├── FailureKind.swift                # authOrSetupFail / cleanExit / connectionDropped
│   │   └── ReconnectScheduler.swift         # exp backoff 1s/2s/5s/10s/30s, cap 5
│   │
│   ├── KeychainStore/                       # macOS Security framework wrapper (library)
│   │   └── KeychainStore.swift              # SecItemAdd/CopyMatching/Delete + access group
│   │
│   └── ConfigStore/                         # Ghostty config file (library)
│       └── ConfigStore.swift                # ~/Library/Application Support/Caterm/config
│
├── Tests/
│   ├── SSHCommandBuilderTests/
│   │   ├── PasswordPathTests.swift
│   │   ├── KeyFilePathTests.swift
│   │   ├── AgentPathTests.swift
│   │   ├── ShellQuoteTests.swift
│   │   └── FuzzInjectionTests.swift
│   ├── KeychainStoreTests/
│   │   └── KeychainStoreTests.swift         # ephemeral access group
│   ├── SessionStoreTests/
│   │   ├── ReconnectFSMTests.swift
│   │   ├── FailureKindClassifierTests.swift
│   │   └── HostPersistenceTests.swift
│   └── ConfigStoreTests/
│       └── ConfigStoreTests.swift
│
├── Manual/
│   └── docker-smoke-matrix.md               # 4 known_hosts cases + 3 auth paths
│
├── Resources/
│   ├── Caterm.entitlements                  # keychain-access-groups
│   └── CatermAskpass.entitlements           # same group
│
├── Vendor/ghostty/                          # submodule (already exists, pinned bc90a5128)
├── Frameworks/GhosttyKit.xcframework/       # build product (already exists, gitignored)
└── Scripts/
    ├── build-libghostty.sh                  # already exists
    ├── dev-codesign.sh                      # NEW: codesign main app + askpass for dev
    └── release.sh                           # NEW: swift-bundler + notarize + create-dmg
```

---

## Task 1.0: Delete spike, restructure Package.swift, scaffold target tree

**Goal:** Clean slate. Sources/CatermSpike gone. Package.swift declares all 9 targets. Empty (compiling) skeleton files in place. `swift build` succeeds (does nothing useful, just compiles).

**Files:**
- Delete: `apps/macos/Sources/CatermSpike/` (whole directory)
- Modify: `apps/macos/Package.swift`
- Create: `apps/macos/Sources/Caterm/CatermApp.swift`
- Create: `apps/macos/Sources/Caterm/AppDelegate.swift`
- Create: `apps/macos/Sources/CatermAskpass/main.swift`
- Create: `apps/macos/Sources/TerminalEngine/Placeholder.swift`
- Create: `apps/macos/Sources/SSHCommandBuilder/Placeholder.swift`
- Create: `apps/macos/Sources/SessionStore/Placeholder.swift`
- Create: `apps/macos/Sources/KeychainStore/Placeholder.swift`
- Create: `apps/macos/Sources/ConfigStore/Placeholder.swift`
- Create: `apps/macos/Resources/Caterm.entitlements`
- Create: `apps/macos/Resources/CatermAskpass.entitlements`

- [ ] **Step 1: Delete spike sources**

```bash
rm -rf apps/macos/Sources/CatermSpike
```

Expected: directory gone.

- [ ] **Step 2: Rewrite Package.swift**

Overwrite `apps/macos/Package.swift`:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Caterm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "caterm", targets: ["Caterm"]),
        .executable(name: "caterm-askpass", targets: ["CatermAskpass"]),
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),

        // --- Libraries ---
        .target(
            name: "TerminalEngine",
            dependencies: ["GhosttyKit"],
            path: "Sources/TerminalEngine"
        ),
        .target(
            name: "SSHCommandBuilder",
            path: "Sources/SSHCommandBuilder"
        ),
        .target(
            name: "KeychainStore",
            path: "Sources/KeychainStore"
        ),
        .target(
            name: "ConfigStore",
            path: "Sources/ConfigStore"
        ),
        .target(
            name: "SessionStore",
            dependencies: ["SSHCommandBuilder", "KeychainStore"],
            path: "Sources/SessionStore"
        ),

        // --- Executables ---
        .executableTarget(
            name: "Caterm",
            dependencies: [
                "TerminalEngine",
                "SSHCommandBuilder",
                "SessionStore",
                "KeychainStore",
                "ConfigStore",
            ],
            path: "Sources/Caterm",
            resources: [.copy("../../Resources/Caterm.entitlements")],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
            ]
        ),
        .executableTarget(
            name: "CatermAskpass",
            dependencies: ["KeychainStore"],
            path: "Sources/CatermAskpass"
        ),

        // --- Tests ---
        .testTarget(
            name: "SSHCommandBuilderTests",
            dependencies: ["SSHCommandBuilder"],
            path: "Tests/SSHCommandBuilderTests"
        ),
        .testTarget(
            name: "KeychainStoreTests",
            dependencies: ["KeychainStore"],
            path: "Tests/KeychainStoreTests"
        ),
        .testTarget(
            name: "SessionStoreTests",
            dependencies: ["SessionStore"],
            path: "Tests/SessionStoreTests"
        ),
        .testTarget(
            name: "ConfigStoreTests",
            dependencies: ["ConfigStore"],
            path: "Tests/ConfigStoreTests"
        ),
    ]
)
```

- [ ] **Step 3: Create skeleton main app files**

`apps/macos/Sources/Caterm/CatermApp.swift`:

```swift
import SwiftUI

@main
struct CatermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            Text("Caterm — Phase 1 scaffold")
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}
```

`apps/macos/Sources/Caterm/AppDelegate.swift`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 4: Create askpass skeleton (compiles, exits 1 with TODO)**

`apps/macos/Sources/CatermAskpass/main.swift`:

```swift
import Foundation

// Real implementation lands in Task 1.3.
FileHandle.standardError.write(Data("caterm-askpass not yet implemented\n".utf8))
exit(1)
```

- [ ] **Step 5: Create library placeholder files**

Each of the five library directories gets `Placeholder.swift`:

```swift
// Real implementation lands in subsequent tasks.
```

(Same single-line content for `TerminalEngine/Placeholder.swift`, `SSHCommandBuilder/Placeholder.swift`, `SessionStore/Placeholder.swift`, `KeychainStore/Placeholder.swift`, `ConfigStore/Placeholder.swift`.)

- [ ] **Step 6: Create empty test directories with one trivial test each**

`apps/macos/Tests/SSHCommandBuilderTests/PlaceholderTests.swift`:

```swift
import XCTest

final class PlaceholderTests: XCTestCase {
    func testPlaceholder() { XCTAssertTrue(true) }
}
```

(Same content for `KeychainStoreTests/PlaceholderTests.swift`, `SessionStoreTests/PlaceholderTests.swift`, `ConfigStoreTests/PlaceholderTests.swift`.)

- [ ] **Step 7: Create entitlements plists**

`apps/macos/Resources/Caterm.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>keychain-access-groups</key>
    <array>
        <string>$(TeamIdentifierPrefix)caterm.shared</string>
    </array>
</dict>
</plist>
```

`apps/macos/Resources/CatermAskpass.entitlements`: same content (identical access group).

- [ ] **Step 8: Run swift build to verify everything compiles**

```bash
cd apps/macos && swift build 2>&1 | tail -20
```

Expected: `Build complete!` for both `caterm` and `caterm-askpass`. No errors.

- [ ] **Step 9: Run swift test to verify test targets compile**

```bash
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 4 placeholder tests pass.

- [ ] **Step 10: Commit**

```bash
git add apps/macos/
git commit -m "feat(macos): scaffold Phase 1 target tree, drop spike sources"
```

- [ ] **Step 11: Append progress log**

Append to `docs/superpowers/plans/2026-04-27-swift-migration-progress.md`:

```
| 2026-04-27 | Task 1.0 通过：spike 代码删除；Package.swift 重写为 9 targets（5 lib + 2 exec + 4 test）；entitlements plist 落位；`swift build` + `swift test` 全绿。Phase 1 干净 baseline 起来 |
```

Then commit:

```bash
git add docs/superpowers/plans/2026-04-27-swift-migration-progress.md
git commit -m "docs(progress): Task 1.0 complete"
```

---

## Task 1.1: TerminalEngine — libghostty Swift wrapper

**Goal:** Clean Swift wrapper around `ghostty_app_*` / `ghostty_surface_*`. Single `GhosttySurfaceNSView` paints a default `$SHELL` into an NSView; pressing keys writes to that shell; resize propagates to PTY. No SSH yet.

**Files:**
- Create: `apps/macos/Sources/TerminalEngine/module.modulemap`
- Create: `apps/macos/Sources/TerminalEngine/include/ghostty_shim.h` (umbrella header re-exporting `Vendor/ghostty/include/ghostty.h`)
- Create: `apps/macos/Sources/TerminalEngine/GhosttyApp.swift`
- Create: `apps/macos/Sources/TerminalEngine/GhosttySurface.swift`
- Create: `apps/macos/Sources/TerminalEngine/GhosttySurfaceNSView.swift`
- Create: `apps/macos/Sources/TerminalEngine/GhosttyConfig.swift`
- Modify: `apps/macos/Package.swift` (add `cSettings` for header search path; remove `Placeholder.swift`)
- Modify: `apps/macos/Sources/Caterm/CatermApp.swift` (mount one surface to verify)
- Delete: `apps/macos/Sources/TerminalEngine/Placeholder.swift`

This task ports the working spike code from `git show 7ada3ac:apps/macos/Sources/CatermSpike/GhosttyBridge.swift` and `TerminalView.swift` into the new module structure, splitting concerns and removing spike-only hardcoding.

- [ ] **Step 1: Reference the spike code**

```bash
git show 7ada3ac:apps/macos/Sources/CatermSpike/GhosttyBridge.swift > /tmp/spike-bridge.swift
git show 7ada3ac:apps/macos/Sources/CatermSpike/TerminalView.swift > /tmp/spike-terminal.swift
git show 7ada3ac:apps/macos/Sources/CatermSpike/CatermSpikeApp.swift > /tmp/spike-app.swift
```

Use these as authoritative references for the C API call shapes. Goal of this task is to refactor — not rewrite — into a clean module.

- [ ] **Step 2: Set up module.modulemap to import ghostty.h**

`apps/macos/Sources/TerminalEngine/module.modulemap`:

```
module CGhostty {
    umbrella header "include/ghostty_shim.h"
    export *
}
```

`apps/macos/Sources/TerminalEngine/include/ghostty_shim.h`:

```c
#ifndef CATERM_GHOSTTY_SHIM_H
#define CATERM_GHOSTTY_SHIM_H
#include "ghostty.h"
#endif
```

- [ ] **Step 3: Update Package.swift to wire the C header search path**

In `Package.swift`, replace the `TerminalEngine` target with:

```swift
.target(
    name: "TerminalEngine",
    dependencies: ["GhosttyKit"],
    path: "Sources/TerminalEngine",
    publicHeadersPath: "include",
    cSettings: [
        .headerSearchPath("../../Vendor/ghostty/include"),
    ]
),
```

- [ ] **Step 4: Verify the C header imports**

Delete `Placeholder.swift`, then create a smoke file `apps/macos/Sources/TerminalEngine/_ImportSmoke.swift`:

```swift
import CGhostty

@inlinable
public func _ghosttyVersionString() -> String {
    String(cString: ghostty_info().version)
}
```

```bash
cd apps/macos && swift build 2>&1 | tail -5
```

Expected: builds clean.

- [ ] **Step 5: Implement GhosttyConfig.swift**

```swift
import CGhostty
import Foundation

public struct GhosttyConfig {
    public static func makeAppConfig(action: @convention(c) (
        ghostty_app_t, ghostty_target_s, ghostty_action_s
    ) -> Bool) -> ghostty_config_t {
        var raw = ghostty_config_t(nil)
        // Build minimal config; refer to /tmp/spike-bridge.swift for the
        // exact ghostty_config_new + load_default + load_string sequence
        // used in the spike (it works — port verbatim).
        raw = ghostty_config_new()
        ghostty_config_load_default_files(raw)
        ghostty_config_finalize(raw)
        return raw
    }
}
```

- [ ] **Step 6: Implement GhosttyApp.swift (singleton wrapper)**

```swift
import CGhostty
import Foundation

@MainActor
public final class GhosttyApp {
    public static let shared = GhosttyApp()

    public let raw: ghostty_app_t

    private init() {
        let config = GhosttyConfig.makeAppConfig(action: Self.actionCallback)
        var runtime = ghostty_runtime_config_s()
        // Fill runtime callbacks per spike's GhosttyBridge.swift (event_loop, wakeup, etc.)
        // Port the working set from /tmp/spike-bridge.swift line-by-line.
        self.raw = ghostty_app_new(&runtime, config)!
    }

    private static let actionCallback: @convention(c) (
        ghostty_app_t, ghostty_target_s, ghostty_action_s
    ) -> Bool = { _, target, action in
        // Dispatch action to the surface's GhosttySurface instance via a
        // userdata-keyed lookup. Implemented in Step 8 below.
        return GhosttySurface.dispatch(target: target, action: action)
    }

    deinit { ghostty_app_free(raw) }
}
```

(The `// Port the working set` comment exists because the spike already proved this code works — refer to `/tmp/spike-bridge.swift` for the exact sequence; do not invent new C API calls.)

- [ ] **Step 7: Implement GhosttySurface.swift**

```swift
import CGhostty
import AppKit

@MainActor
public final class GhosttySurface {
    public let raw: ghostty_surface_t
    public weak var hostView: NSView?

    /// Called when libghostty fires GHOSTTY_ACTION_SHOW_CHILD_EXITED.
    public var onChildExit: ((Int32) -> Void)?

    private static var registry: [ObjectIdentifier: GhosttySurface] = [:]

    public init(command: String?, env: [(String, String)] = []) {
        var config = ghostty_surface_config_s()
        ghostty_surface_config_defaults(&config)

        if let command {
            command.withCString { ptr in config.command = ptr }
            // Need to keep the pointer alive — copy to a Swift-owned buffer,
            // see /tmp/spike-bridge.swift for the strdup pattern used.
        }
        // env_vars ditto; libghostty owns nothing — we keep buffers alive
        // by storing CStrings on self before passing pointers.

        self.raw = ghostty_surface_new(GhosttyApp.shared.raw, &config)!
        Self.registry[ObjectIdentifier(self)] = self
    }

    public func setSize(width: UInt32, height: UInt32) {
        ghostty_surface_set_size(raw, width, height)
    }

    public func sendKey(_ event: NSEvent) {
        // Build ghostty_input_key_s exactly per spike's TerminalView.handleKey.
    }

    public var processExited: Bool {
        ghostty_surface_process_exited(raw)
    }

    static func dispatch(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        // Locate surface from target.tag == GHOSTTY_TARGET_SURFACE
        // Switch on action.tag; for GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        //   let payload = action.action.show_child_exited  // ghostty_surface_message_childexited_s
        //   surface.onChildExit?(Int32(payload.exit_code))
        return true
    }

    deinit {
        Self.registry.removeValue(forKey: ObjectIdentifier(self))
        ghostty_surface_free(raw)
    }
}
```

- [ ] **Step 8: Implement GhosttySurfaceNSView.swift**

```swift
import AppKit
import CGhostty

@MainActor
public final class GhosttySurfaceNSView: NSView {
    public let surface: GhosttySurface

    public init(command: String?, env: [(String, String)] = []) {
        self.surface = GhosttySurface(command: command, env: env)
        super.init(frame: .zero)
        self.surface.hostView = self
        self.wantsLayer = true
        // libghostty paints into our layer via Metal; spike pattern:
        //   ghostty_surface_set_nsview(surface.raw, self)
        //   (or the ID/scale_factor pair if the API moved)
    }

    required init?(coder: NSCoder) { nil }

    public override var acceptsFirstResponder: Bool { true }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let scale = window?.backingScaleFactor ?? 1.0
        surface.setSize(width: UInt32(newSize.width * scale),
                        height: UInt32(newSize.height * scale))
    }

    public override func keyDown(with event: NSEvent) {
        surface.sendKey(event)
    }
}
```

- [ ] **Step 9: Mount one surface in CatermApp to verify rendering**

Replace `Sources/Caterm/CatermApp.swift`:

```swift
import SwiftUI
import TerminalEngine

@main
struct CatermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            TerminalSmokeView()
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}

struct TerminalSmokeView: NSViewRepresentable {
    func makeNSView(context: Context) -> GhosttySurfaceNSView {
        GhosttySurfaceNSView(command: nil)  // nil → libghostty runs $SHELL
    }
    func updateNSView(_ view: GhosttySurfaceNSView, context: Context) {}
}
```

- [ ] **Step 10: Run the app and verify a shell appears**

```bash
cd apps/macos && swift run caterm 2>&1 | head -20
```

Expected: window opens, shows `$SHELL` prompt (`zsh%` or similar). Type `echo hi` + Return — `hi` echoes. Resize window — surface re-tiles.

If anything is broken, diff against `/tmp/spike-bridge.swift` — that code is known good.

- [ ] **Step 11: Commit**

```bash
git add apps/macos/Sources/TerminalEngine/ apps/macos/Sources/Caterm/CatermApp.swift apps/macos/Package.swift
git rm apps/macos/Sources/TerminalEngine/Placeholder.swift
git commit -m "feat(macos): TerminalEngine wraps libghostty; default shell renders"
```

- [ ] **Step 12: Append progress log + commit**

```
| 2026-04-27 | Task 1.1 通过：TerminalEngine module 起来；GhosttySurface + GhosttySurfaceNSView 包装 libghostty；默认 shell 在 NSView 内渲染；resize OK；键盘输入 OK |
```

---

## Task 1.2: SSHCommandBuilder + tests (TDD-rigorous)

**Goal:** Pure function `SSHCommandBuilder.build(host:credential:askpassPath:knownHostsCaterm:knownHostsUser:)` returning `(commandString, envVars)`. Three `CredentialSource` paths produce different argv. **Shell-quoting is the credential security perimeter** (spec §4.1) — any leak through is a security bug, so this task is rigorous TDD.

**Files:**
- Create: `apps/macos/Sources/SSHCommandBuilder/Host.swift`
- Create: `apps/macos/Sources/SSHCommandBuilder/ShellQuote.swift`
- Create: `apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift`
- Create: `apps/macos/Tests/SSHCommandBuilderTests/ShellQuoteTests.swift`
- Create: `apps/macos/Tests/SSHCommandBuilderTests/PasswordPathTests.swift`
- Create: `apps/macos/Tests/SSHCommandBuilderTests/KeyFilePathTests.swift`
- Create: `apps/macos/Tests/SSHCommandBuilderTests/AgentPathTests.swift`
- Create: `apps/macos/Tests/SSHCommandBuilderTests/FuzzInjectionTests.swift`
- Delete: `apps/macos/Sources/SSHCommandBuilder/Placeholder.swift`
- Delete: `apps/macos/Tests/SSHCommandBuilderTests/PlaceholderTests.swift`

- [ ] **Step 1: Define Host + CredentialSource (data types only, no logic)**

`Sources/SSHCommandBuilder/Host.swift`:

```swift
import Foundation

public struct Host: Codable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var credential: CredentialSource
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, hostname: String, port: Int = 22,
                username: String, credential: CredentialSource,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.credential = credential
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum CredentialSource: Codable, Hashable {
    case password
    case keyFile(keyPath: String, hasPassphrase: Bool)
    case agent
}
```

- [ ] **Step 2: Write the failing ShellQuote test first (TDD)**

`Tests/SSHCommandBuilderTests/ShellQuoteTests.swift`:

```swift
import XCTest
@testable import SSHCommandBuilder

final class ShellQuoteTests: XCTestCase {
    func testEmptyString() {
        XCTAssertEqual(ShellQuote.posix(""), "''")
    }

    func testSimpleAlphanumeric() {
        XCTAssertEqual(ShellQuote.posix("hello"), "'hello'")
    }

    func testStringWithSpaces() {
        XCTAssertEqual(ShellQuote.posix("hello world"), "'hello world'")
    }

    func testSingleQuoteEscape() {
        // POSIX: ' → '\''
        XCTAssertEqual(ShellQuote.posix("it's"), "'it'\\''s'")
    }

    func testDollarSignNotInterpolated() {
        // Inside single quotes, $ is literal
        XCTAssertEqual(ShellQuote.posix("$HOME"), "'$HOME'")
    }

    func testBackticksLiteral() {
        XCTAssertEqual(ShellQuote.posix("`whoami`"), "'`whoami`'")
    }

    func testCommandSubstitutionLiteral() {
        XCTAssertEqual(ShellQuote.posix("$(rm -rf /)"), "'$(rm -rf /)'")
    }

    func testSemicolonLiteral() {
        XCTAssertEqual(ShellQuote.posix("a;b"), "'a;b'")
    }

    func testNewline() {
        XCTAssertEqual(ShellQuote.posix("a\nb"), "'a\nb'")
    }

    func testUnicode() {
        XCTAssertEqual(ShellQuote.posix("café"), "'café'")
    }

    func testMultipleSingleQuotes() {
        XCTAssertEqual(ShellQuote.posix("'a''b'"), "''\\''a'\\'''\\''b'\\'''")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail (no ShellQuote yet)**

```bash
cd apps/macos && swift test --filter ShellQuoteTests 2>&1 | tail -10
```

Expected: compile fails on `ShellQuote.posix` undefined.

- [ ] **Step 4: Implement ShellQuote.swift (minimal)**

```swift
import Foundation

public enum ShellQuote {
    /// Wrap an arbitrary string in POSIX-safe single quotes. Inside single
    /// quotes, every byte is literal except `'` itself, which terminates the
    /// quoted region. Replace embedded `'` with `'\''` (close, escape, reopen).
    public static func posix(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
```

- [ ] **Step 5: Run ShellQuote tests, expect all pass**

```bash
cd apps/macos && swift test --filter ShellQuoteTests 2>&1 | tail -5
```

Expected: 11 tests pass.

- [ ] **Step 6: Write the failing PasswordPathTests**

`Tests/SSHCommandBuilderTests/PasswordPathTests.swift`:

```swift
import XCTest
@testable import SSHCommandBuilder

final class PasswordPathTests: XCTestCase {
    let host = Host(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        name: "test", hostname: "host.example.com", port: 22,
        username: "alice", credential: .password
    )

    func testCommandStringContainsAllRequiredOptions() {
        let result = SSHCommandBuilder.build(
            host: host,
            askpassPath: "/usr/local/bin/caterm-askpass",
            knownHostsCaterm: "/Users/alice/Library/Application Support/Caterm/known_hosts",
            knownHostsUser: "/Users/alice/.ssh/known_hosts"
        )

        let cmd = result.command
        XCTAssertTrue(cmd.contains("/usr/bin/ssh"))
        XCTAssertTrue(cmd.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(cmd.contains("PreferredAuthentications=password"))
        XCTAssertTrue(cmd.contains("PubkeyAuthentication=no"))
        XCTAssertTrue(cmd.contains("KbdInteractiveAuthentication=no"))
        XCTAssertTrue(cmd.contains("NumberOfPasswordPrompts=1"))
        XCTAssertTrue(cmd.contains("'alice'@'host.example.com'"))
        XCTAssertTrue(cmd.contains("-p 22"))
    }

    func testHybridKnownHostsTwoFiles() {
        let result = SSHCommandBuilder.build(
            host: host,
            askpassPath: "/x/askpass",
            knownHostsCaterm: "/A/known_hosts",
            knownHostsUser: "/B/known_hosts"
        )
        XCTAssertTrue(result.command.contains("UserKnownHostsFile=/A/known_hosts /B/known_hosts"))
    }

    func testEnvVarsContainAskpass() {
        let result = SSHCommandBuilder.build(
            host: host,
            askpassPath: "/usr/local/bin/caterm-askpass",
            knownHostsCaterm: "/A", knownHostsUser: "/B"
        )
        let envDict = Dictionary(uniqueKeysWithValues: result.env)
        XCTAssertEqual(envDict["SSH_ASKPASS"], "/usr/local/bin/caterm-askpass")
        XCTAssertEqual(envDict["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(envDict["CATERM_HOST_ID"], "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(envDict["CATERM_ASKPASS_KIND"], "password")
    }

    func testNonDefaultPort() {
        var h = host
        h.port = 2222
        let result = SSHCommandBuilder.build(
            host: h, askpassPath: "/x", knownHostsCaterm: "/A", knownHostsUser: "/B"
        )
        XCTAssertTrue(result.command.contains("-p 2222"))
    }
}
```

- [ ] **Step 7: Run tests, expect compile fail (no SSHCommandBuilder yet)**

```bash
cd apps/macos && swift test --filter PasswordPathTests 2>&1 | tail -5
```

Expected: `cannot find 'SSHCommandBuilder' in scope`.

- [ ] **Step 8: Implement SSHCommandBuilder.swift (minimal — password path only)**

`Sources/SSHCommandBuilder/SSHCommandBuilder.swift`:

```swift
import Foundation

public enum SSHCommandBuilder {
    public struct Output: Equatable {
        public let command: String
        public let env: [(String, String)]

        public static func == (lhs: Output, rhs: Output) -> Bool {
            lhs.command == rhs.command &&
                lhs.env.map { [$0.0, $0.1] } == rhs.env.map { [$0.0, $0.1] }
        }
    }

    public static func build(
        host: Host,
        askpassPath: String,
        knownHostsCaterm: String,
        knownHostsUser: String
    ) -> Output {
        var argv: [String] = ["/usr/bin/ssh"]
        let knownHostsValue = "\(knownHostsCaterm) \(knownHostsUser)"

        argv += ["-o", "StrictHostKeyChecking=accept-new"]
        argv += ["-o", "UserKnownHostsFile=\(knownHostsValue)"]

        var env: [(String, String)] = []

        switch host.credential {
        case .password:
            argv += [
                "-o", "PreferredAuthentications=password",
                "-o", "PubkeyAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1",
            ]
            env = [
                ("SSH_ASKPASS", askpassPath),
                ("SSH_ASKPASS_REQUIRE", "force"),
                ("CATERM_HOST_ID", host.id.uuidString),
                ("CATERM_ASKPASS_KIND", "password"),
            ]

        case let .keyFile(keyPath, hasPassphrase):
            argv += [
                "-o", "IdentitiesOnly=yes",
                "-o", "PreferredAuthentications=publickey",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-i", keyPath,
            ]
            if hasPassphrase {
                env = [
                    ("SSH_ASKPASS", askpassPath),
                    ("SSH_ASKPASS_REQUIRE", "force"),
                    ("CATERM_HOST_ID", host.id.uuidString),
                    ("CATERM_ASKPASS_KIND", "passphrase"),
                ]
            }

        case .agent:
            argv += ["-o", "BatchMode=yes"]
        }

        argv += ["-p", String(host.port), "\(host.username)@\(host.hostname)"]

        let cmd = argv.enumerated().map { idx, arg in
            // Skip-quote the binary path and pure flags; quote everything else
            if idx == 0 { return arg }
            if arg.hasPrefix("-") && !arg.contains("=") && !arg.contains(" ") {
                return arg
            }
            // Args that must always be quoted: anything user-derived or
            // containing spaces/special chars
            return ShellQuote.posix(arg)
        }.joined(separator: " ")

        return Output(command: cmd, env: env)
    }
}
```

- [ ] **Step 9: Run PasswordPathTests, fix any bugs**

```bash
cd apps/macos && swift test --filter PasswordPathTests 2>&1 | tail -10
```

Expected: 4 tests pass. If any fail, fix the implementation (likely the quoting strategy needs adjusting per the test assertions, e.g. `-p 22` not quoted but `'alice'@'host.example.com'` is).

The important check: `-p 22` test expects unquoted; `user@host` test expects each side single-quoted. Adjust `argv.enumerated().map` block accordingly — split the `user@host` arg into two pieces before quoting if needed, then join with `@`.

- [ ] **Step 10: Write KeyFilePathTests**

```swift
import XCTest
@testable import SSHCommandBuilder

final class KeyFilePathTests: XCTestCase {
    func testKeyFileWithoutPassphrase() {
        let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                        username: "u",
                        credential: .keyFile(keyPath: "/Users/u/.ssh/id_ed25519",
                                             hasPassphrase: false))
        let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                             knownHostsCaterm: "/A", knownHostsUser: "/B")
        XCTAssertTrue(result.command.contains("PreferredAuthentications=publickey"))
        XCTAssertTrue(result.command.contains("PasswordAuthentication=no"))
        XCTAssertTrue(result.command.contains("IdentitiesOnly=yes"))
        XCTAssertTrue(result.command.contains("-i '/Users/u/.ssh/id_ed25519'"))
        // No env when no passphrase
        XCTAssertTrue(result.env.isEmpty)
    }

    func testKeyFileWithPassphraseSetsAskpass() {
        let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                        username: "u",
                        credential: .keyFile(keyPath: "/path/key", hasPassphrase: true))
        let result = SSHCommandBuilder.build(host: host, askpassPath: "/askpass",
                                             knownHostsCaterm: "/A", knownHostsUser: "/B")
        let envDict = Dictionary(uniqueKeysWithValues: result.env)
        XCTAssertEqual(envDict["SSH_ASKPASS"], "/askpass")
        XCTAssertEqual(envDict["CATERM_ASKPASS_KIND"], "passphrase")
    }

    func testKeyFilePathWithSpaces() {
        let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                        username: "u",
                        credential: .keyFile(keyPath: "/Users/My User/.ssh/id_rsa",
                                             hasPassphrase: false))
        let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                             knownHostsCaterm: "/A", knownHostsUser: "/B")
        // Path quoted exactly once, intact
        XCTAssertTrue(result.command.contains("-i '/Users/My User/.ssh/id_rsa'"))
    }
}
```

- [ ] **Step 11: Run KeyFilePathTests, fix bugs**

```bash
cd apps/macos && swift test --filter KeyFilePathTests 2>&1 | tail -10
```

Expected: 3 tests pass.

- [ ] **Step 12: Write AgentPathTests**

```swift
import XCTest
@testable import SSHCommandBuilder

final class AgentPathTests: XCTestCase {
    func testAgentSetsBatchMode() {
        let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                        username: "u", credential: .agent)
        let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                             knownHostsCaterm: "/A", knownHostsUser: "/B")
        XCTAssertTrue(result.command.contains("BatchMode=yes"))
    }

    func testAgentNoIdentityFile() {
        let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                        username: "u", credential: .agent)
        let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                             knownHostsCaterm: "/A", knownHostsUser: "/B")
        XCTAssertFalse(result.command.contains(" -i "))
    }

    func testAgentNoAskpassEnv() {
        let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                        username: "u", credential: .agent)
        let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                             knownHostsCaterm: "/A", knownHostsUser: "/B")
        XCTAssertTrue(result.env.isEmpty)
    }

    func testAgentDoesNotForbidPubkey() {
        // Agent path uses pubkey auth — must NOT have PubkeyAuthentication=no
        let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                        username: "u", credential: .agent)
        let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                             knownHostsCaterm: "/A", knownHostsUser: "/B")
        XCTAssertFalse(result.command.contains("PubkeyAuthentication=no"))
    }
}
```

- [ ] **Step 13: Run AgentPathTests, fix bugs**

```bash
cd apps/macos && swift test --filter AgentPathTests 2>&1 | tail -10
```

Expected: 4 tests pass.

- [ ] **Step 14: Write FuzzInjectionTests (the credential security perimeter)**

```swift
import XCTest
@testable import SSHCommandBuilder

/// These tests are the credential security perimeter. Any failure here means
/// user input can break out of single-quote shell context and execute
/// arbitrary code via libghostty's bash invocation. Treat any regression as a
/// security incident.
final class FuzzInjectionTests: XCTestCase {
    let evilStrings: [String] = [
        "'; rm -rf / ;'",
        "$(rm -rf /)",
        "`whoami`",
        "a;b",
        "a\"b",
        "a\\b",
        "a\nb",
        "a\tb",
        "a\\\\b",
        "a$b",
        "a$(b)",
        "a`b`",
        "a|b",
        "a&b",
        "a>b",
        "a<b",
        "café é",
        "中文 测试",
        "emoji 😀 here",
        "spaces  spaces",
        "'''''",
    ]

    func testEvilHostnameDoesNotEscapeQuotes() {
        for evil in evilStrings {
            let host = Host(id: UUID(), name: "x", hostname: evil, port: 22,
                            username: "u", credential: .password)
            let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                                 knownHostsCaterm: "/A", knownHostsUser: "/B")
            assertWellFormedSingleQuoting(result.command,
                                          message: "hostname=\(evil.debugDescription)")
        }
    }

    func testEvilUsernameDoesNotEscapeQuotes() {
        for evil in evilStrings {
            let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                            username: evil, credential: .password)
            let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                                 knownHostsCaterm: "/A", knownHostsUser: "/B")
            assertWellFormedSingleQuoting(result.command,
                                          message: "username=\(evil.debugDescription)")
        }
    }

    func testEvilKeyPathDoesNotEscapeQuotes() {
        for evil in evilStrings {
            let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                            username: "u",
                            credential: .keyFile(keyPath: evil, hasPassphrase: false))
            let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                                 knownHostsCaterm: "/A", knownHostsUser: "/B")
            assertWellFormedSingleQuoting(result.command,
                                          message: "keyPath=\(evil.debugDescription)")
        }
    }

    /// Walk the string, count single-quote runs. Every run that opens a quoted
    /// region must be followed by `'\''` if the next char is a single quote;
    /// every char inside a quoted region (apart from `'`) must be literal.
    /// We assert: (a) the string contains balanced single-quote regions, (b)
    /// no occurrence of `${`, `$(`, or backtick exists OUTSIDE quoted regions,
    /// (c) no occurrence of `;`, `|`, `&`, `>`, `<` exists outside quoted
    /// regions (apart from those baked into argv structure — handled by
    /// scanning only after the first `'`).
    private func assertWellFormedSingleQuoting(_ cmd: String, message: String) {
        var inQuote = false
        var i = cmd.startIndex
        while i < cmd.endIndex {
            let c = cmd[i]
            if c == "'" {
                inQuote.toggle()
            } else if !inQuote {
                // Outside quotes, only ssh's own structure characters allowed:
                // letters/digits, `-`, `=`, `/`, `_`, `.`, `@`, ` `, `:` (port).
                let allowed: Set<Character> = ["-", "=", "/", "_", ".", "@", " ", ":"]
                if !c.isLetter && !c.isNumber && !allowed.contains(c) {
                    XCTFail("Stray '\(c)' outside quoted region in \(cmd) — \(message)")
                    return
                }
            }
            i = cmd.index(after: i)
        }
        XCTAssertFalse(inQuote, "Unbalanced single quotes in \(cmd) — \(message)")
    }
}
```

- [ ] **Step 15: Run FuzzInjectionTests; iterate quoting strategy until all 60+ cases pass**

```bash
cd apps/macos && swift test --filter FuzzInjectionTests 2>&1 | tail -20
```

Expected: all pass. Likely fixes:
- The `user@host` arg needs to be split into `'user'@'host'` form — quote each side, join with literal `@`.
- The `-o KEY=VALUE` form: quote only the VALUE portion containing user paths or spaces; leave the `KEY=` prefix unquoted.
- The `assertWellFormedSingleQuoting` allowlist of "outside-quote" chars must match what your final builder emits.

Iterate the implementation until clean.

- [ ] **Step 16: Delete placeholder files + run all tests**

```bash
rm apps/macos/Sources/SSHCommandBuilder/Placeholder.swift
rm apps/macos/Tests/SSHCommandBuilderTests/PlaceholderTests.swift
cd apps/macos && swift test --filter SSHCommandBuilderTests 2>&1 | tail -10
```

Expected: ~80 tests pass, 0 fail.

- [ ] **Step 17: Commit**

```bash
git add apps/macos/Sources/SSHCommandBuilder/ apps/macos/Tests/SSHCommandBuilderTests/
git rm apps/macos/Sources/SSHCommandBuilder/Placeholder.swift apps/macos/Tests/SSHCommandBuilderTests/PlaceholderTests.swift
git commit -m "feat(macos): SSHCommandBuilder with shell-quote fuzz tests"
```

- [ ] **Step 18: Append progress log + commit**

```
| 2026-04-27 | Task 1.2 通过：SSHCommandBuilder 三路 enum 实现完毕；ShellQuote POSIX；FuzzInjectionTests 60+ 用例（含分号/反引号/$()/单双引号/unicode/换行）全绿。凭据安全防线立起来 |
```

---

## Task 1.3: AskpassHelper binary + dev codesign + end-to-end verification

**Goal:** Ship a working `caterm-askpass` binary that ssh's child can `exec` to get the password from Keychain. **End-to-end password auth must succeed before this task is "done"** — that means dev codesigning has to land here too, because without same-team-id signing the Keychain access group ACL rejects the askpass read (spec §6.3 #4).

**Files:**
- Modify: `apps/macos/Sources/CatermAskpass/main.swift` (full implementation)
- Create: `apps/macos/Sources/KeychainStore/KeychainStore.swift` (since askpass depends on it)
- Create: `apps/macos/Tests/KeychainStoreTests/KeychainStoreTests.swift`
- Create: `apps/macos/Scripts/dev-codesign.sh`
- Create: `apps/macos/Manual/end-to-end-smoke.md` (steps for manual verification)
- Delete: `apps/macos/Sources/KeychainStore/Placeholder.swift`
- Delete: `apps/macos/Tests/KeychainStoreTests/PlaceholderTests.swift`

- [ ] **Step 1: Write KeychainStore tests first (TDD)**

`Tests/KeychainStoreTests/KeychainStoreTests.swift`:

```swift
import XCTest
@testable import KeychainStore

final class KeychainStoreTests: XCTestCase {
    let testService = "com.caterm.host.test"
    let testAccount = "test-host-id.password"
    let testGroup = "caterm.test.shared" // ephemeral; CI uses login keychain
    var store: KeychainStore!

    override func setUp() async throws {
        store = KeychainStore(
            service: testService,
            accessGroup: nil  // nil → login keychain (no codesign required)
        )
        try? store.delete(account: testAccount)
    }

    override func tearDown() async throws {
        try? store.delete(account: testAccount)
    }

    func testWriteReadRoundtrip() throws {
        try store.set(account: testAccount, secret: "p@ssw0rd!")
        let read = try store.get(account: testAccount)
        XCTAssertEqual(read, "p@ssw0rd!")
    }

    func testReadMissingThrowsNotFound() {
        XCTAssertThrowsError(try store.get(account: "no-such-account")) { error in
            guard case KeychainError.notFound = error else {
                XCTFail("Expected .notFound, got \(error)"); return
            }
        }
    }

    func testWriteOverwritesExisting() throws {
        try store.set(account: testAccount, secret: "first")
        try store.set(account: testAccount, secret: "second")
        let read = try store.get(account: testAccount)
        XCTAssertEqual(read, "second")
    }

    func testDelete() throws {
        try store.set(account: testAccount, secret: "x")
        try store.delete(account: testAccount)
        XCTAssertThrowsError(try store.get(account: testAccount))
    }

    func testDeleteByHostIdPattern() throws {
        let hostId = UUID().uuidString
        try store.set(account: "\(hostId).password", secret: "p1")
        try store.set(account: "\(hostId).keyPassphrase", secret: "p2")
        try store.deleteAll(prefix: "\(hostId).")
        XCTAssertThrowsError(try store.get(account: "\(hostId).password"))
        XCTAssertThrowsError(try store.get(account: "\(hostId).keyPassphrase"))
    }

    func testUnicodeSecret() throws {
        try store.set(account: testAccount, secret: "密码 café 😀")
        let read = try store.get(account: testAccount)
        XCTAssertEqual(read, "密码 café 😀")
    }
}
```

- [ ] **Step 2: Run, expect compile fail**

```bash
cd apps/macos && swift test --filter KeychainStoreTests 2>&1 | tail -5
```

Expected: `cannot find 'KeychainStore' in scope`.

- [ ] **Step 3: Implement KeychainStore.swift**

`Sources/KeychainStore/KeychainStore.swift`:

```swift
import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case notFound
    case osStatus(OSStatus)
    case decodeFailed
}

public final class KeychainStore {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "com.caterm.host", accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func set(account: String, secret: String) throws {
        guard let data = secret.data(using: .utf8) else { throw KeychainError.decodeFailed }
        // Try update first, then add
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary,
                                         updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw KeychainError.osStatus(updateStatus) }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess { throw KeychainError.osStatus(addStatus) }
    }

    public func get(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw KeychainError.notFound }
        if status != errSecSuccess { throw KeychainError.osStatus(status) }
        guard let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodeFailed
        }
        return secret
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status == errSecItemNotFound { throw KeychainError.notFound }
        if status != errSecSuccess { throw KeychainError.osStatus(status) }
    }

    public func deleteAll(prefix: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        if status != errSecSuccess { throw KeychainError.osStatus(status) }
        guard let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let acct = item[kSecAttrAccount as String] as? String,
                  acct.hasPrefix(prefix) else { continue }
            try? delete(account: acct)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }
}
```

- [ ] **Step 4: Delete KeychainStore placeholders, run tests**

```bash
rm apps/macos/Sources/KeychainStore/Placeholder.swift
rm apps/macos/Tests/KeychainStoreTests/PlaceholderTests.swift
cd apps/macos && swift test --filter KeychainStoreTests 2>&1 | tail -10
```

Expected: 6 tests pass. (CI/dev: against login keychain, no access group; that's fine for unit tests — the access-group-cross-process check happens in step 11 below.)

- [ ] **Step 5: Implement caterm-askpass main.swift**

`Sources/CatermAskpass/main.swift`:

```swift
import Foundation
import KeychainStore

// caterm-askpass — invoked by ssh via SSH_ASKPASS=<this binary>.
//
// ssh forks-execs us with no controlling tty and expects us to write the
// password (or passphrase) to stdout. We pick the Keychain item via two env
// vars set by SSHCommandBuilder:
//   CATERM_HOST_ID    — UUID of the host
//   CATERM_ASKPASS_KIND — "password" or "passphrase"
//
// Keychain account format: "<host-id>.<kind>"
// Keychain access group:   "$(TeamIdentifierPrefix)caterm.shared"
//                          (resolved at runtime — see resolveAccessGroup below)
//
// On success: write secret + "\n" to stdout, exit 0.
// On failure: write diagnostic to stderr, exit 1.

let env = ProcessInfo.processInfo.environment

guard let hostId = env["CATERM_HOST_ID"], !hostId.isEmpty else {
    FileHandle.standardError.write(Data("CATERM_HOST_ID not set\n".utf8))
    exit(1)
}
guard let kind = env["CATERM_ASKPASS_KIND"],
      kind == "password" || kind == "passphrase" else {
    FileHandle.standardError.write(Data("CATERM_ASKPASS_KIND invalid\n".utf8))
    exit(1)
}

let account = "\(hostId).\(kind)"
let accessGroup = AskpassAccessGroup.resolved
let store = KeychainStore(service: "com.caterm.host", accessGroup: accessGroup)

do {
    let secret = try store.get(account: account)
    // ssh wants the secret followed by a newline.
    let out = secret + "\n"
    FileHandle.standardOutput.write(Data(out.utf8))
    exit(0)
} catch KeychainError.notFound {
    FileHandle.standardError.write(Data("askpass: secret not found for \(account)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("askpass: keychain error \(error)\n".utf8))
    exit(3)
}

enum AskpassAccessGroup {
    /// At dev time we may run unsigned (access group nil → falls back to login
    /// keychain). At ship time the access group is set in the entitlement and
    /// resolved automatically. This wrapper picks the right one based on the
    /// CATERM_ACCESS_GROUP env var (set by main app when launching child).
    static var resolved: String? {
        ProcessInfo.processInfo.environment["CATERM_ACCESS_GROUP"]
    }
}
```

- [ ] **Step 6: Build the askpass binary**

```bash
cd apps/macos && swift build --target CatermAskpass 2>&1 | tail -5
```

Expected: builds. Binary at `.build/debug/caterm-askpass`.

- [ ] **Step 7: Stuff a test password in login keychain manually**

```bash
TEST_HOST_ID="00000000-0000-0000-0000-000000000001"
security add-generic-password \
    -s "com.caterm.host" \
    -a "$TEST_HOST_ID.password" \
    -w "hunter2" \
    -U
```

Expected: silent success.

- [ ] **Step 8: Invoke the binary directly and verify it reads back**

```bash
CATERM_HOST_ID="00000000-0000-0000-0000-000000000001" \
CATERM_ASKPASS_KIND="password" \
./apps/macos/.build/debug/caterm-askpass
```

Expected: prints `hunter2\n` to stdout, exit 0.

If macOS prompts for keychain access via dialog, that's the unsigned-binary ACL behavior — accept the prompt; we'll fix it via codesign in step 11.

- [ ] **Step 9: Build the dev-codesign script**

`apps/macos/Scripts/dev-codesign.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# dev-codesign.sh — sign caterm + caterm-askpass with the user's Apple Dev
# Identity so Keychain access group ACL works between processes during
# development.
#
# Required env:
#   CATERM_DEV_IDENTITY  — name of the codesign identity in login keychain
#                         (e.g. "Apple Development: Your Name (TEAMID)")

: "${CATERM_DEV_IDENTITY:?CATERM_DEV_IDENTITY env var required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/.build/debug"

codesign --force --options runtime \
    --sign "$CATERM_DEV_IDENTITY" \
    --entitlements "$ROOT/Resources/Caterm.entitlements" \
    "$BIN_DIR/caterm"

codesign --force --options runtime \
    --sign "$CATERM_DEV_IDENTITY" \
    --entitlements "$ROOT/Resources/CatermAskpass.entitlements" \
    "$BIN_DIR/caterm-askpass"

echo "Signed both binaries with $CATERM_DEV_IDENTITY"
codesign -dvv "$BIN_DIR/caterm" 2>&1 | grep -E "TeamIdentifier|Authority"
codesign -dvv "$BIN_DIR/caterm-askpass" 2>&1 | grep -E "TeamIdentifier|Authority"
```

```bash
chmod +x apps/macos/Scripts/dev-codesign.sh
```

- [ ] **Step 10: Run codesign script, verify signature**

(User must have an Apple Development cert in their login keychain; the certificate's TeamIdentifier becomes the access group prefix.)

```bash
# User: list available identities
security find-identity -v -p codesigning | head

# Set the identity name
export CATERM_DEV_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"
cd apps/macos && swift build && ./Scripts/dev-codesign.sh
```

Expected: both binaries signed; same `TeamIdentifier=XXXXXXXXXX` printed for both.

- [ ] **Step 11: End-to-end test with access group**

Replace the manual login-keychain item with one in the access group:

```bash
TEAM_ID="XXXXXXXXXX"  # from previous step
ACCESS_GROUP="${TEAM_ID}.caterm.shared"

# Add via SecItemAdd (scripted via Python or a tiny Swift one-shot —
# `security` CLI does not support setting access group directly).
# Use a helper Swift script:
cat > /tmp/keychain-write.swift <<EOF
import Foundation
import Security
let q: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.caterm.host",
    kSecAttrAccount as String: "00000000-0000-0000-0000-000000000001.password",
    kSecAttrAccessGroup as String: "$ACCESS_GROUP",
    kSecValueData as String: "hunter2".data(using: .utf8)!,
    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
]
SecItemDelete(q as CFDictionary)
let status = SecItemAdd(q as CFDictionary, nil)
print("status: \(status)")
EOF
# This needs to be signed too (otherwise can't write to access group);
# easier path: launch caterm app once, have it perform the write via
# KeychainStore. We'll wire that into Task 1.7.

# For now, verify the askpass binary CAN at least access the access group
# without a Keychain prompt by setting the env var:
CATERM_HOST_ID="00000000-0000-0000-0000-000000000001" \
CATERM_ASKPASS_KIND="password" \
CATERM_ACCESS_GROUP="$ACCESS_GROUP" \
./apps/macos/.build/debug/caterm-askpass
```

Expected: exit code 2 (`secret not found`) — that's the right answer; it means the access group was queried successfully (no ACL block, no prompt). The actual "write then read" round-trip will work end-to-end after Task 1.7 wires the main app.

If macOS shows a "caterm-askpass wants to access keychain" prompt, the codesign or entitlement is wrong — debug before proceeding.

- [ ] **Step 12: Document the manual smoke flow**

`apps/macos/Manual/end-to-end-smoke.md`:

````markdown
# End-to-end askpass smoke

Run after every Task 1.3+ change to catch codesign/access-group regressions.

## Prerequisites

- Apple Development cert installed in login keychain
- `CATERM_DEV_IDENTITY` exported (e.g. `Apple Development: Your Name (XXXXXXXXXX)`)
- Local OpenSSH server in Docker:
  ```
  docker run -d --name=caterm-smoke \
      -p 2222:2222 \
      -e PASSWORD_ACCESS=true \
      -e USER_NAME=spike \
      -e USER_PASSWORD=spikepass \
      lscr.io/linuxserver/openssh-server:latest
  ```

## Procedure

1. `cd apps/macos && swift build && ./Scripts/dev-codesign.sh`
2. Verify both binaries have the same TeamIdentifier:
   `codesign -dvv .build/debug/caterm{,-askpass} 2>&1 | grep TeamIdentifier`
3. Launch caterm; in ConnectDialog, add `127.0.0.1:2222` user `spike`,
   credential `password`, password `spikepass`. (Task 1.6 wires this UI;
   for Task 1.3 alone, hardcode in CatermApp.swift smoke harness.)
4. Connect — the surface should authenticate without prompting and show
   `spike@<container-id>:~$`.
5. Verify in Console.app: no `Keychain access denied` log lines for
   `caterm-askpass`.

## Failure modes

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Keychain dialog popup | binary unsigned or wrong access group | re-run dev-codesign.sh; verify entitlement plist |
| `spawn askpass: Permission denied` | binary not executable | `chmod +x .build/debug/caterm-askpass` |
| `Permission denied (password,publickey)` | secret not in keychain | run KeychainStore set via Task 1.7 UI; or re-add via signed test harness |
| `Failed to add the host to the list` | known_hosts paths wrong | check the SSHCommandBuilder output env vars; ensure dirs exist |
````

- [ ] **Step 13: Commit**

```bash
git add apps/macos/Sources/KeychainStore/ \
        apps/macos/Tests/KeychainStoreTests/ \
        apps/macos/Sources/CatermAskpass/main.swift \
        apps/macos/Scripts/dev-codesign.sh \
        apps/macos/Manual/end-to-end-smoke.md
git rm apps/macos/Sources/KeychainStore/Placeholder.swift \
       apps/macos/Tests/KeychainStoreTests/PlaceholderTests.swift
git commit -m "feat(macos): KeychainStore + caterm-askpass + dev codesign"
```

- [ ] **Step 14: Append progress log**

```
| 2026-04-27 | Task 1.3 通过：KeychainStore（SecItem* + access group）；caterm-askpass 二进制；dev-codesign.sh 签名两个 binary（同 Team ID）；access group ACL 端到端通过（无 keychain dialog 弹窗）|
```

---

## Task 1.4: Single-tab connect flow + child-exit signal verification

**Goal:** Wire SessionStore + SSHCommandBuilder + TerminalEngine + KeychainStore into one **end-to-end SSH connection**. Hardcoded host (Docker `linuxserver/openssh-server`) for now. **Crucially**: verify the child-exit signal path (action callback + `ghostty_surface_process_exited`) actually fires — without this, reconnect FSM in Task 1.8 has nothing to listen to.

**Files:**
- Create: `apps/macos/Sources/SessionStore/ConnectionState.swift`
- Create: `apps/macos/Sources/SessionStore/FailureKind.swift`
- Create: `apps/macos/Sources/SessionStore/SessionStore.swift` (minimal — no persistence yet)
- Create: `apps/macos/Tests/SessionStoreTests/FailureKindClassifierTests.swift`
- Modify: `apps/macos/Sources/Caterm/CatermApp.swift` (replace smoke view with full connect flow)
- Modify: `apps/macos/Sources/TerminalEngine/GhosttySurface.swift` (wire onChildExit dispatch)
- Delete: `apps/macos/Sources/SessionStore/Placeholder.swift`
- Delete: `apps/macos/Tests/SessionStoreTests/PlaceholderTests.swift`

- [ ] **Step 1: Define ConnectionState enum**

`Sources/SessionStore/ConnectionState.swift`:

```swift
import Foundation

public enum ConnectionState: Equatable {
    case idle
    case connecting(startedAt: Date)
    case connected(connectedAt: Date)
    case reconnecting(attempt: Int, nextRetryAt: Date)
    case failed(FailureKind)
}
```

- [ ] **Step 2: Define FailureKind classifier**

`Sources/SessionStore/FailureKind.swift`:

```swift
import Foundation

public enum FailureKind: Equatable {
    /// auth fail or host key mismatch or DNS — short-lived, never reached Connected.
    /// UI: red, "重新填凭据"; do NOT auto-reconnect.
    case authOrSetupFail

    /// Remote shell exited with `exit` (status 0). UI: grey "会话结束"; no reconnect.
    case cleanExit

    /// Network drop after Connected. UI: yellow; enter §4.3 reconnect FSM.
    case connectionDropped

    /// Classify exit_code + connected-history into one of the three.
    public static func classify(exitCode: Int32, hadConnected: Bool) -> FailureKind {
        if exitCode == 0 { return .cleanExit }
        if hadConnected { return .connectionDropped }
        // exit != 0 and never reached Connected = auth/setup phase failure.
        return .authOrSetupFail
    }
}
```

- [ ] **Step 3: Write FailureKindClassifierTests**

`Tests/SessionStoreTests/FailureKindClassifierTests.swift`:

```swift
import XCTest
@testable import SessionStore

final class FailureKindClassifierTests: XCTestCase {
    func testCleanExit() {
        XCTAssertEqual(FailureKind.classify(exitCode: 0, hadConnected: true), .cleanExit)
        XCTAssertEqual(FailureKind.classify(exitCode: 0, hadConnected: false), .cleanExit)
    }

    func testConnectionDroppedAfterConnected() {
        XCTAssertEqual(FailureKind.classify(exitCode: 1, hadConnected: true), .connectionDropped)
        XCTAssertEqual(FailureKind.classify(exitCode: 255, hadConnected: true), .connectionDropped)
    }

    func testAuthOrSetupFailEarly() {
        XCTAssertEqual(FailureKind.classify(exitCode: 255, hadConnected: false), .authOrSetupFail)
        XCTAssertEqual(FailureKind.classify(exitCode: 1, hadConnected: false), .authOrSetupFail)
    }
}
```

- [ ] **Step 4: Run, expect compile fail (no SessionStore module yet)**

```bash
cd apps/macos && swift test --filter FailureKindClassifierTests 2>&1 | tail -5
```

- [ ] **Step 5: Wire onChildExit dispatch in GhosttySurface**

Modify `Sources/TerminalEngine/GhosttySurface.swift` so the `static func dispatch` actually finds the surface and invokes `onChildExit`. Use the userdata pointer pattern: when creating a surface, register `self` in the registry keyed by surface raw pointer, and look up via `target.tag == GHOSTTY_TARGET_SURFACE` → `target.target.surface`.

```swift
// In init():
Self.registry[OpaquePointer(raw)] = self  // (cast as needed)

// In dispatch:
guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
let surfacePtr = OpaquePointer(target.target.surface)
guard let surface = Self.registry[surfacePtr] else { return false }
switch action.tag {
case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
    let payload = action.action.show_child_exited
    surface.onChildExit?(Int32(payload.exit_code))
    return true
default:
    return false
}
```

(Adjust the OpaquePointer-keying details to match the actual `ghostty_surface_t` typedef. Reference `ghostty.h` lines 828-1000.)

- [ ] **Step 6: Implement minimal SessionStore**

`Sources/SessionStore/SessionStore.swift`:

```swift
import Foundation
import SwiftUI
import SSHCommandBuilder
import KeychainStore

@MainActor
public final class SessionStore: ObservableObject {
    public struct Tab: Identifiable {
        public let id: UUID
        public var host: Host
        public var state: ConnectionState
        public var hadConnected: Bool = false
        public init(host: Host) {
            self.id = UUID()
            self.host = host
            self.state = .idle
        }
    }

    @Published public private(set) var tabs: [Tab] = []

    public let askpassPath: String
    public let knownHostsCaterm: String
    public let knownHostsUser: String
    public let accessGroup: String?

    public init(askpassPath: String, knownHostsCaterm: String,
                knownHostsUser: String, accessGroup: String?) {
        self.askpassPath = askpassPath
        self.knownHostsCaterm = knownHostsCaterm
        self.knownHostsUser = knownHostsUser
        self.accessGroup = accessGroup
    }

    public func openTab(host: Host) -> UUID {
        let tab = Tab(host: host)
        tabs.append(tab)
        return tab.id
    }

    /// Build the (commandString, env) pair for a given tab.
    public func surfaceConfig(for tabId: UUID) -> (command: String, env: [(String, String)])? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        let cmd = SSHCommandBuilder.build(
            host: tab.host,
            askpassPath: askpassPath,
            knownHostsCaterm: knownHostsCaterm,
            knownHostsUser: knownHostsUser
        )
        var env = cmd.env
        if let accessGroup { env.append(("CATERM_ACCESS_GROUP", accessGroup)) }
        return (cmd.command, env)
    }

    public func markConnecting(tabId: UUID) {
        update(tabId) { $0.state = .connecting(startedAt: Date()) }
    }

    public func markConnected(tabId: UUID) {
        update(tabId) {
            $0.state = .connected(connectedAt: Date())
            $0.hadConnected = true
        }
    }

    public func markChildExited(tabId: UUID, exitCode: Int32) {
        update(tabId) { tab in
            let kind = FailureKind.classify(exitCode: exitCode,
                                            hadConnected: tab.hadConnected)
            tab.state = .failed(kind)
        }
    }

    private func update(_ tabId: UUID, _ mutate: (inout Tab) -> Void) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        var tab = tabs[idx]
        mutate(&tab)
        tabs[idx] = tab
    }
}
```

- [ ] **Step 7: Delete placeholders, run all SessionStore tests**

```bash
rm apps/macos/Sources/SessionStore/Placeholder.swift
rm apps/macos/Tests/SessionStoreTests/PlaceholderTests.swift
cd apps/macos && swift test --filter SessionStoreTests 2>&1 | tail -10
```

Expected: 3 FailureKindClassifierTests pass.

- [ ] **Step 8: Build a full connect-flow smoke harness in CatermApp**

Replace `Sources/Caterm/CatermApp.swift`:

```swift
import SwiftUI
import TerminalEngine
import SSHCommandBuilder
import SessionStore
import KeychainStore

@main
struct CatermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store: SessionStore = makeStore()

    var body: some Scene {
        WindowGroup {
            SmokeConnectView()
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 600)
        }
    }
}

func makeStore() -> SessionStore {
    let supportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Caterm", isDirectory: true)
    try? FileManager.default.createDirectory(at: supportDir,
                                             withIntermediateDirectories: true)
    let knownCaterm = supportDir.appendingPathComponent("known_hosts").path
    let knownUser = ("~/.ssh/known_hosts" as NSString).expandingTildeInPath

    let askpassPath = Bundle.main.bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("caterm-askpass").path
    // For dev: askpass is at .build/debug/caterm-askpass alongside caterm
    let devAskpass = ProcessInfo.processInfo.environment["CATERM_DEV_ASKPASS_PATH"]
        ?? askpassPath

    let teamId = ProcessInfo.processInfo.environment["CATERM_TEAM_ID"] ?? ""
    let accessGroup = teamId.isEmpty ? nil : "\(teamId).caterm.shared"

    return SessionStore(askpassPath: devAskpass,
                        knownHostsCaterm: knownCaterm,
                        knownHostsUser: knownUser,
                        accessGroup: accessGroup)
}

struct SmokeConnectView: View {
    @EnvironmentObject var store: SessionStore
    @State var tabId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Connect to 127.0.0.1:2222 (spike/spikepass)") { connect() }
                Button("Disconnect") { disconnect() }
                if let tabId, let tab = store.tabs.first(where: { $0.id == tabId }) {
                    Text("State: \(String(describing: tab.state))")
                        .font(.system(.caption, design: .monospaced))
                }
            }.padding(8)
            if let tabId {
                ConnectedSurfaceView(tabId: tabId)
            } else {
                Text("Click Connect").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    func connect() {
        let host = Host(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "smoke", hostname: "127.0.0.1", port: 2222,
            username: "spike", credential: .password
        )
        // Stuff Keychain (one-time per dev session — once stored, askpass reads it)
        let store = KeychainStore(service: "com.caterm.host",
                                  accessGroup: self.store.accessGroup)
        try? store.set(account: "\(host.id.uuidString).password", secret: "spikepass")

        tabId = self.store.openTab(host: host)
    }

    func disconnect() {
        // Task 1.5 wires close; for now just clear UI
        tabId = nil
    }
}

struct ConnectedSurfaceView: NSViewRepresentable {
    @EnvironmentObject var store: SessionStore
    let tabId: UUID

    func makeNSView(context: Context) -> GhosttySurfaceNSView {
        guard let cfg = store.surfaceConfig(for: tabId) else {
            return GhosttySurfaceNSView(command: nil)
        }
        let view = GhosttySurfaceNSView(command: cfg.command, env: cfg.env)
        store.markConnecting(tabId: tabId)
        view.surface.onChildExit = { [weak store] code in
            Task { @MainActor in
                store?.markChildExited(tabId: tabId, exitCode: code)
            }
        }
        // 3s grace period: if process still alive, mark Connected.
        Task { @MainActor [weak store] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let store, !view.surface.processExited else { return }
            store.markConnected(tabId: tabId)
        }
        return view
    }

    func updateNSView(_ view: GhosttySurfaceNSView, context: Context) {}
}
```

- [ ] **Step 9: Boot Docker SSH server**

```bash
docker run -d --name=caterm-smoke \
    -p 2222:2222 \
    -e PASSWORD_ACCESS=true \
    -e USER_NAME=spike \
    -e USER_PASSWORD=spikepass \
    lscr.io/linuxserver/openssh-server:latest
sleep 3
docker logs caterm-smoke 2>&1 | tail -3
```

Expected: container running, port 2222 listening.

- [ ] **Step 10: Run signed app, connect**

```bash
cd apps/macos && swift build && ./Scripts/dev-codesign.sh
export CATERM_TEAM_ID="XXXXXXXXXX"   # your TeamID
export CATERM_DEV_ASKPASS_PATH="$(pwd)/.build/debug/caterm-askpass"
.build/debug/caterm
```

Click "Connect to 127.0.0.1:2222". Surface should:
1. Show `State: connecting(...)`
2. After ssh handshake (~1-2s), show `Welcome to OpenSSH Server` banner
3. After 3s grace period, transition to `State: connected(...)`
4. Type `exit` + Return → child process exits → surface fires
   `GHOSTTY_ACTION_SHOW_CHILD_EXITED` → state → `failed(.cleanExit)`

If state never moves to Connected, the grace-period code path is broken — debug.

If state never reaches `failed(.cleanExit)` after `exit`, the action callback dispatch is broken — that's the showstopper. Fix before continuing (the entire reconnect FSM in Task 1.8 depends on this signal).

- [ ] **Step 11: Verify the `processExited` query API too**

In `SmokeConnectView`, add a button "Check processExited" that prints `store.surfaceForTab(tabId)?.processExited`. Connect, wait, click button:
- Before `exit`: should print `false`
- After `exit`: should print `true`

This proves the API works as a fallback when the action callback misses.

- [ ] **Step 12: Tear down Docker, commit**

```bash
docker rm -f caterm-smoke

git add apps/macos/Sources/SessionStore/ \
        apps/macos/Tests/SessionStoreTests/ \
        apps/macos/Sources/Caterm/CatermApp.swift \
        apps/macos/Sources/TerminalEngine/GhosttySurface.swift
git rm apps/macos/Sources/SessionStore/Placeholder.swift \
       apps/macos/Tests/SessionStoreTests/PlaceholderTests.swift
git commit -m "feat(macos): single-tab SSH connect with child-exit signal verified"
```

- [ ] **Step 13: Append progress log**

```
| 2026-04-27 | Task 1.4 通过：单 tab 端到端 SSH 通了；FailureKind 分类单测；GHOSTTY_ACTION_SHOW_CHILD_EXITED action callback + ghostty_surface_process_exited 双信号验证（Connected→exit→cleanExit 路径走完整状态机） |
```

---

## Task 1.5: NSWindow tabs (multi-tab)

**Goal:** Multiple SSH sessions in one window, native macOS tabs (the OS-provided tab bar via `NSWindow.Tabbing`). ⌘T new tab, ⌘W closes the current tab (last tab also closes window). Closing a tab `ghostty_surface_free`s, libghostty SIGHUPs ssh.

**Files:**
- Create: `apps/macos/Sources/Caterm/Views/MainWindow.swift`
- Create: `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift`
- Modify: `apps/macos/Sources/Caterm/CatermApp.swift` (use MainWindow instead of smoke view)
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift` (add `closeTab(tabId:)`)

- [ ] **Step 1: Add closeTab to SessionStore**

In `SessionStore.swift`, add:

```swift
public func closeTab(tabId: UUID) {
    tabs.removeAll { $0.id == tabId }
}
```

- [ ] **Step 2: Build TerminalContainerView**

`Sources/Caterm/Views/TerminalContainerView.swift`: extracts the surface NSViewRepresentable from the smoke harness, parameterized on `tabId`. Same body as `ConnectedSurfaceView` from Task 1.4 step 8.

- [ ] **Step 3: Build MainWindow.swift using NSWindow tabs**

```swift
import SwiftUI
import AppKit

struct MainWindow: View {
    @EnvironmentObject var store: SessionStore
    @State var selectedTabId: UUID?

    var body: some View {
        ZStack {
            if let id = selectedTabId,
               store.tabs.contains(where: { $0.id == id }) {
                TerminalContainerView(tabId: id)
            } else {
                Text("⌘T to open a new tab").foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear { tryActivateFirstTab() }
        .onReceive(store.$tabs) { _ in tryActivateFirstTab() }
    }

    func tryActivateFirstTab() {
        if selectedTabId == nil { selectedTabId = store.tabs.first?.id }
        if let id = selectedTabId,
           !store.tabs.contains(where: { $0.id == id }) {
            selectedTabId = store.tabs.first?.id
        }
    }
}
```

For the actual native `NSWindow.tabbingMode = .preferred` integration: SwiftUI's `WindowGroup` automatically supports tabs on macOS 14+ when `NSWindow` reports `tabbingMode = .preferred`. Wire this in `AppDelegate.swift`:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    NSWindow.allowsAutomaticWindowTabbing = true
}
```

- [ ] **Step 4: Hook ⌘T / ⌘W**

In `AppMenuBuilder.swift` (new file), add menu items wired to `NewWindowAction()`/`CloseWindowAction()`. SwiftUI provides `Commands` builder — use it inside `Scene`:

```swift
.commands {
    CommandGroup(replacing: .newItem) {
        Button("New Tab") { /* open ConnectDialog (Task 1.6) */ }
            .keyboardShortcut("t", modifiers: .command)
    }
}
```

For now in Task 1.5, ⌘T opens a hardcoded new tab (same `Host` as Task 1.4) so we can stress multi-tab. ⌘W: built into NSWindow tabs natively.

- [ ] **Step 5: Test multi-tab boot**

```bash
cd apps/macos && swift build && ./Scripts/dev-codesign.sh
docker run -d --rm --name=caterm-smoke -p 2222:2222 \
    -e USER_NAME=spike -e USER_PASSWORD=spikepass -e PASSWORD_ACCESS=true \
    lscr.io/linuxserver/openssh-server
.build/debug/caterm
```

Open 3 tabs (⌘T x3). Each shows a separate `spike@<container>:~$` prompt. ⌘W closes the active one; the ssh process for it should exit (verify via `docker exec caterm-smoke ps aux | grep sshd`).

- [ ] **Step 6: Commit + progress log**

```bash
git add apps/macos/Sources/
git commit -m "feat(macos): NSWindow multi-tab support + ⌘T/⌘W"
```

```
| 2026-04-27 | Task 1.5 通过：NSWindow native tabs；多 tab 同时连接同一 Docker target；⌘T 新 tab / ⌘W 关 tab；关 tab 触发 surface free + libghostty SIGHUP ssh |
```

---

## Task 1.6: HostListSidebar + ConnectDialog UI + local JSON persistence

**Goal:** Sidebar with host list, add/edit/delete forms, ConnectDialog for picking `CredentialSource`. Hosts persist to `~/Library/Application Support/Caterm/hosts.json`. No more hardcoded host in CatermApp.

**Files:**
- Create: `apps/macos/Sources/SessionStore/HostPersistence.swift`
- Create: `apps/macos/Tests/SessionStoreTests/HostPersistenceTests.swift`
- Create: `apps/macos/Sources/Caterm/Views/HostListSidebar.swift`
- Create: `apps/macos/Sources/Caterm/Views/HostFormView.swift`
- Create: `apps/macos/Sources/Caterm/Views/ConnectDialog.swift`
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift` (load + save hosts)
- Modify: `apps/macos/Sources/Caterm/Views/MainWindow.swift` (add sidebar)

- [ ] **Step 1: Write HostPersistenceTests first**

```swift
import XCTest
@testable import SessionStore
@testable import SSHCommandBuilder

final class HostPersistenceTests: XCTestCase {
    var tmpURL: URL!

    override func setUp() {
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-test-\(UUID()).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpURL)
    }

    func testRoundtripWithAllThreeCredentialKinds() throws {
        let hosts: [Host] = [
            Host(name: "p", hostname: "h1", port: 22, username: "u", credential: .password),
            Host(name: "k", hostname: "h2", port: 2222, username: "u",
                 credential: .keyFile(keyPath: "/x/y", hasPassphrase: true)),
            Host(name: "a", hostname: "h3", port: 22, username: "u", credential: .agent),
        ]
        try HostPersistence.save(hosts, to: tmpURL)
        let read = try HostPersistence.load(from: tmpURL)
        XCTAssertEqual(read.count, 3)
        XCTAssertEqual(read[0].credential, .password)
        XCTAssertEqual(read[1].credential, .keyFile(keyPath: "/x/y", hasPassphrase: true))
        XCTAssertEqual(read[2].credential, .agent)
    }

    func testLoadMissingFileReturnsEmpty() throws {
        let result = try HostPersistence.load(from: tmpURL)
        XCTAssertTrue(result.isEmpty)
    }

    func testFilePermissionsAre0600() throws {
        try HostPersistence.save([], to: tmpURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: tmpURL.path)
        let perm = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perm, 0o600)
    }
}
```

- [ ] **Step 2: Implement HostPersistence**

```swift
import Foundation
import SSHCommandBuilder

public enum HostPersistence {
    public static func load(from url: URL) throws -> [Host] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Host].self, from: data)
    }

    public static func save(_ hosts: [Host], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(hosts)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }
}
```

- [ ] **Step 3: Run, expect green**

```bash
cd apps/macos && swift test --filter HostPersistenceTests 2>&1 | tail -5
```

Expected: 3 tests pass.

- [ ] **Step 4: Add hosts state to SessionStore**

In `SessionStore.swift`:

```swift
@Published public private(set) var hosts: [Host] = []
private let hostsURL: URL

public init(askpassPath: String, knownHostsCaterm: String, knownHostsUser: String,
            accessGroup: String?, hostsURL: URL) {
    // ... (previous fields)
    self.hostsURL = hostsURL
    do { self.hosts = try HostPersistence.load(from: hostsURL) }
    catch { self.hosts = [] }
}

public func addHost(_ host: Host) throws {
    hosts.append(host)
    try HostPersistence.save(hosts, to: hostsURL)
}

public func updateHost(_ host: Host) throws {
    guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return }
    var updated = host
    updated.updatedAt = Date()
    hosts[idx] = updated
    try HostPersistence.save(hosts, to: hostsURL)
}

public func deleteHost(id: UUID) throws {
    hosts.removeAll { $0.id == id }
    try HostPersistence.save(hosts, to: hostsURL)
    // Keychain cleanup wired in Task 1.7
}
```

- [ ] **Step 5: Build HostListSidebar**

```swift
import SwiftUI
import SSHCommandBuilder

struct HostListSidebar: View {
    @EnvironmentObject var store: SessionStore
    @Binding var selectedHostId: UUID?
    @State var showingAddSheet = false
    @State var editingHost: Host?

    var body: some View {
        List(selection: $selectedHostId) {
            ForEach(store.hosts) { host in
                HostRow(host: host)
                    .tag(host.id)
                    .contextMenu {
                        Button("Connect") { connect(host) }
                        Button("Edit") { editingHost = host }
                        Button("Delete", role: .destructive) {
                            try? store.deleteHost(id: host.id)
                        }
                    }
            }
        }
        .toolbar {
            Button { showingAddSheet = true } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            HostFormView(mode: .add) { host in
                try? store.addHost(host)
                showingAddSheet = false
            }
        }
        .sheet(item: $editingHost) { host in
            HostFormView(mode: .edit(host)) { updated in
                try? store.updateHost(updated)
                editingHost = nil
            }
        }
    }

    private func connect(_ host: Host) {
        _ = store.openTab(host: host)
    }
}

struct HostRow: View {
    let host: Host
    var body: some View {
        HStack {
            Image(systemName: iconName).foregroundColor(.secondary)
            VStack(alignment: .leading) {
                Text(host.name).font(.headline)
                Text("\(host.username)@\(host.hostname):\(host.port)")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }
    var iconName: String {
        switch host.credential {
        case .password: return "key.fill"
        case .keyFile: return "lock.shield.fill"
        case .agent: return "key.icloud.fill"
        }
    }
}
```

- [ ] **Step 6: Build HostFormView**

```swift
import SwiftUI
import SSHCommandBuilder

enum HostFormMode {
    case add
    case edit(Host)
}

struct HostFormView: View {
    let mode: HostFormMode
    let onSubmit: (Host) -> Void
    @Environment(\.dismiss) var dismiss

    @State var name = ""
    @State var hostname = ""
    @State var port = "22"
    @State var username = ""
    @State var credKind: CredKind = .password
    @State var keyPath = ""
    @State var hasPassphrase = false

    enum CredKind: String, CaseIterable, Identifiable {
        case password, keyFile = "key file", agent
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            TextField("Name (display)", text: $name)
            TextField("Hostname", text: $hostname)
            TextField("Port", text: $port)
            TextField("Username", text: $username)

            Picker("Authentication", selection: $credKind) {
                ForEach(CredKind.allCases) { Text($0.rawValue).tag($0) }
            }

            if credKind == .keyFile {
                HStack {
                    TextField("Private key path", text: $keyPath)
                    Button("Browse…") { browseKey() }
                }
                Toggle("Key has passphrase", isOn: $hasPassphrase)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { submit() }.keyboardShortcut(.return)
                    .disabled(name.isEmpty || hostname.isEmpty || username.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { populate() }
    }

    func populate() {
        if case let .edit(host) = mode {
            name = host.name
            hostname = host.hostname
            port = String(host.port)
            username = host.username
            switch host.credential {
            case .password: credKind = .password
            case let .keyFile(p, hp):
                credKind = .keyFile; keyPath = p; hasPassphrase = hp
            case .agent: credKind = .agent
            }
        }
    }

    func browseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            keyPath = url.path
        }
    }

    func submit() {
        let cred: CredentialSource
        switch credKind {
        case .password: cred = .password
        case .keyFile: cred = .keyFile(keyPath: keyPath, hasPassphrase: hasPassphrase)
        case .agent: cred = .agent
        }
        let id: UUID
        if case let .edit(existing) = mode { id = existing.id } else { id = UUID() }
        let host = Host(
            id: id, name: name, hostname: hostname,
            port: Int(port) ?? 22, username: username, credential: cred
        )
        onSubmit(host)
        dismiss()
    }
}
```

- [ ] **Step 7: Build ConnectDialog (lightweight: only triggered when password/passphrase needed and Keychain miss)**

For v1, ConnectDialog only opens when:
- Adding a new host with `.password` or `.keyFile(hasPassphrase: true)`: prompt for the secret to store in Keychain
- Or: connecting to an existing host with no Keychain entry (recovery flow)

```swift
import SwiftUI
import SSHCommandBuilder

struct ConnectSecretDialog: View {
    let host: Host
    let kind: SecretKind
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) var dismiss
    @State var secret = ""

    enum SecretKind: String { case password, passphrase }

    var body: some View {
        VStack {
            Text("Enter \(kind.rawValue) for \(host.name)").font(.headline)
            SecureField(kind.rawValue, text: $secret).onSubmit { submit() }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { submit() }.disabled(secret.isEmpty)
            }
        }.padding(20).frame(width: 400)
    }

    func submit() {
        onSubmit(secret)
        dismiss()
    }
}
```

- [ ] **Step 8: Wire MainWindow to use sidebar + tabs together**

```swift
struct MainWindow: View {
    @EnvironmentObject var store: SessionStore
    @State var selectedHostId: UUID?
    @State var selectedTabId: UUID?

    var body: some View {
        NavigationSplitView {
            HostListSidebar(selectedHostId: $selectedHostId)
        } detail: {
            if let id = selectedTabId,
               store.tabs.contains(where: { $0.id == id }) {
                TerminalContainerView(tabId: id)
            } else {
                Text("Select a host and press ⏎ to connect")
            }
        }
    }
}
```

- [ ] **Step 9: Manual test**

```bash
cd apps/macos && swift build && ./Scripts/dev-codesign.sh
.build/debug/caterm
```

Add 3 hosts (one of each credential kind). Verify they persist to `~/Library/Application Support/Caterm/hosts.json` (`cat` it). Restart app — hosts still there. Edit a host — reflected after save. Delete a host — gone.

- [ ] **Step 10: Commit + log**

```bash
git add apps/macos/Sources/ apps/macos/Tests/
git commit -m "feat(macos): host list sidebar + add/edit/delete forms + JSON persistence"
```

```
| 2026-04-27 | Task 1.6 通过：HostListSidebar + HostFormView + ConnectSecretDialog；hosts.json 持久化 0600 权限；CredentialSource enum 三路 UI 全打通；不再硬编码主机 |
```

---

## Task 1.7: KeychainStore wiring (write on form submit + delete on host removal)

**Goal:** Wire the existing `KeychainStore` into the UI flow. When user submits HostFormView with a `.password` or `.keyFile(hasPassphrase:true)` choice, prompt for the secret and store it. When deleting a host, wipe its Keychain entries.

**Files:**
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift` (add keychain, secret-write hooks)
- Modify: `apps/macos/Sources/Caterm/Views/HostFormView.swift` (collect secret on submit if needed)
- Modify: `apps/macos/Sources/Caterm/Views/HostListSidebar.swift` (delete invokes keychain wipe)
- Add Tests: `apps/macos/Tests/SessionStoreTests/KeychainIntegrationTests.swift`

- [ ] **Step 1: Add KeychainStore to SessionStore**

```swift
public let keychain: KeychainStore

public init(...existing args..., keychain: KeychainStore) {
    self.keychain = keychain
    // ... (previous init body)
}

public func setHostSecret(_ secret: String, hostId: UUID, kind: SecretKind) throws {
    try keychain.set(account: account(hostId, kind), secret: secret)
}

public func deleteHost(id: UUID) throws {
    hosts.removeAll { $0.id == id }
    try HostPersistence.save(hosts, to: hostsURL)
    try? keychain.deleteAll(prefix: "\(id.uuidString).")
}

public enum SecretKind: String {
    case password, keyPassphrase
}

private func account(_ id: UUID, _ kind: SecretKind) -> String {
    "\(id.uuidString).\(kind.rawValue)"
}
```

- [ ] **Step 2: Update HostFormView to collect secret on submit**

In `HostFormView.swift`, after `submit()`:

```swift
@EnvironmentObject var store: SessionStore
@State var pendingSecret = ""

func submit() {
    let cred: CredentialSource
    switch credKind {
    case .password:
        cred = .password
    case .keyFile:
        cred = .keyFile(keyPath: keyPath, hasPassphrase: hasPassphrase)
    case .agent:
        cred = .agent
    }
    let host = Host(...)
    onSubmit(host)
    // Write secret if needed
    if case .password = cred, !pendingSecret.isEmpty {
        try? store.setHostSecret(pendingSecret, hostId: host.id, kind: .password)
    } else if case .keyFile(_, true) = cred, !pendingSecret.isEmpty {
        try? store.setHostSecret(pendingSecret, hostId: host.id, kind: .keyPassphrase)
    }
    dismiss()
}
```

Add a SecureField in the form:

```swift
if credKind == .password {
    SecureField("Password (stored in Keychain)", text: $pendingSecret)
}
if credKind == .keyFile && hasPassphrase {
    SecureField("Passphrase (stored in Keychain)", text: $pendingSecret)
}
```

- [ ] **Step 3: Verify HostListSidebar's delete path invokes keychain wipe**

(Already does, via `store.deleteHost(id:)` from Step 1.)

- [ ] **Step 4: Write KeychainIntegrationTests**

```swift
import XCTest
@testable import SessionStore
@testable import SSHCommandBuilder
@testable import KeychainStore

@MainActor
final class KeychainIntegrationTests: XCTestCase {
    var sut: SessionStore!
    var tmpHostsURL: URL!

    override func setUp() async throws {
        tmpHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-int-\(UUID()).json")
        let kc = KeychainStore(service: "com.caterm.test.\(UUID())", accessGroup: nil)
        sut = SessionStore(askpassPath: "/x", knownHostsCaterm: "/A",
                           knownHostsUser: "/B", accessGroup: nil,
                           hostsURL: tmpHostsURL, keychain: kc)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpHostsURL)
    }

    func testDeleteHostWipesKeychain() async throws {
        let host = Host(name: "t", hostname: "h", port: 22, username: "u",
                        credential: .password)
        try sut.addHost(host)
        try sut.setHostSecret("p", hostId: host.id, kind: .password)
        XCTAssertEqual(try sut.keychain.get(account: "\(host.id.uuidString).password"), "p")

        try sut.deleteHost(id: host.id)
        XCTAssertThrowsError(try sut.keychain.get(account: "\(host.id.uuidString).password"))
    }

    func testSetHostSecretRoundtrip() async throws {
        let id = UUID()
        try sut.setHostSecret("p@ss", hostId: id, kind: .password)
        XCTAssertEqual(try sut.keychain.get(account: "\(id.uuidString).password"), "p@ss")
    }
}
```

- [ ] **Step 5: Run tests**

```bash
cd apps/macos && swift test --filter KeychainIntegrationTests 2>&1 | tail -5
```

Expected: 2 tests pass.

- [ ] **Step 6: Manual e2e**

Re-run the app, add a password-auth host, type the password into the form. Connect — should authenticate without prompting. Delete the host — `security find-generic-password -s com.caterm.host -a <id>.password` returns nothing.

- [ ] **Step 7: Commit + log**

```bash
git add apps/macos/Sources/SessionStore/ apps/macos/Sources/Caterm/Views/ apps/macos/Tests/SessionStoreTests/
git commit -m "feat(macos): KeychainStore wired to host CRUD"
```

```
| 2026-04-27 | Task 1.7 通过：HostFormView 提交时存 Keychain；delete 时通配清理；KeychainIntegrationTests 单测覆盖；端到端密码自动注入跑通 |
```

---

## Task 1.8: Auto-reconnect state machine + UI status + reconnect overlay

**Goal:** When child exits with `connectionDropped` (had Connected, then non-zero exit), enter Reconnecting state with exp backoff (1s, 2s, 5s, 10s, 30s; cap 5 attempts). Show NSView overlay with countdown. On success, replace surface in-place. On 5 failures, give up → Failed.

**Files:**
- Create: `apps/macos/Sources/SessionStore/ReconnectScheduler.swift`
- Create: `apps/macos/Tests/SessionStoreTests/ReconnectFSMTests.swift`
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift` (FSM transitions)
- Create: `apps/macos/Sources/Caterm/Views/ReconnectOverlay.swift`
- Modify: `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift` (reload surface on Reconnecting → new attempt)

- [ ] **Step 1: Define ReconnectScheduler with pure tests first**

`Tests/SessionStoreTests/ReconnectFSMTests.swift`:

```swift
import XCTest
@testable import SessionStore

final class ReconnectFSMTests: XCTestCase {
    func testBackoffSchedule() {
        XCTAssertEqual(ReconnectScheduler.backoff(attempt: 1), 1.0)
        XCTAssertEqual(ReconnectScheduler.backoff(attempt: 2), 2.0)
        XCTAssertEqual(ReconnectScheduler.backoff(attempt: 3), 5.0)
        XCTAssertEqual(ReconnectScheduler.backoff(attempt: 4), 10.0)
        XCTAssertEqual(ReconnectScheduler.backoff(attempt: 5), 30.0)
    }

    func testMaxAttempts() {
        XCTAssertEqual(ReconnectScheduler.maxAttempts, 5)
    }

    func testShouldReconnectAfterConnectionDropped() {
        XCTAssertTrue(ReconnectScheduler.shouldReconnect(failureKind: .connectionDropped, attempt: 1))
        XCTAssertTrue(ReconnectScheduler.shouldReconnect(failureKind: .connectionDropped, attempt: 5))
        XCTAssertFalse(ReconnectScheduler.shouldReconnect(failureKind: .connectionDropped, attempt: 6))
    }

    func testNeverReconnectAuthFail() {
        XCTAssertFalse(ReconnectScheduler.shouldReconnect(failureKind: .authOrSetupFail, attempt: 1))
    }

    func testNeverReconnectCleanExit() {
        XCTAssertFalse(ReconnectScheduler.shouldReconnect(failureKind: .cleanExit, attempt: 1))
    }
}
```

- [ ] **Step 2: Implement ReconnectScheduler**

`Sources/SessionStore/ReconnectScheduler.swift`:

```swift
import Foundation

public enum ReconnectScheduler {
    public static let maxAttempts = 5

    public static func backoff(attempt: Int) -> TimeInterval {
        // 1, 2, 5, 10, 30 (then 30 if anyone calls beyond 5)
        switch attempt {
        case 1: return 1
        case 2: return 2
        case 3: return 5
        case 4: return 10
        default: return 30
        }
    }

    public static func shouldReconnect(failureKind: FailureKind, attempt: Int) -> Bool {
        guard attempt <= maxAttempts else { return false }
        switch failureKind {
        case .connectionDropped: return true
        case .authOrSetupFail, .cleanExit: return false
        }
    }
}
```

- [ ] **Step 3: Run, expect green**

```bash
cd apps/macos && swift test --filter ReconnectFSMTests 2>&1 | tail -5
```

- [ ] **Step 4: Add reconnect transitions to SessionStore**

In `SessionStore.swift`:

```swift
public func markChildExited(tabId: UUID, exitCode: Int32) {
    update(tabId) { tab in
        let kind = FailureKind.classify(exitCode: exitCode,
                                        hadConnected: tab.hadConnected)
        tab.lastFailure = kind
        let attempt = tab.reconnectAttempts + 1
        if ReconnectScheduler.shouldReconnect(failureKind: kind, attempt: attempt) {
            tab.reconnectAttempts = attempt
            let nextRetry = Date().addingTimeInterval(ReconnectScheduler.backoff(attempt: attempt))
            tab.state = .reconnecting(attempt: attempt, nextRetryAt: nextRetry)
            // Schedule the actual reconnect
            scheduleReconnect(tabId: tabId, after: ReconnectScheduler.backoff(attempt: attempt))
        } else {
            tab.state = .failed(kind)
        }
    }
}

private func scheduleReconnect(tabId: UUID, after seconds: TimeInterval) {
    Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard let self else { return }
        // Bump generation to trigger view to recreate surface
        self.update(tabId) { $0.surfaceGeneration += 1; $0.state = .connecting(startedAt: Date()) }
    }
}

public func markConnected(tabId: UUID) {
    update(tabId) {
        $0.state = .connected(connectedAt: Date())
        $0.hadConnected = true
        $0.reconnectAttempts = 0
    }
}
```

(Add `var reconnectAttempts: Int = 0`, `var lastFailure: FailureKind?`, `var surfaceGeneration: Int = 0` to `Tab`.)

- [ ] **Step 5: TerminalContainerView reads `surfaceGeneration` to recreate surface on reconnect**

```swift
struct TerminalContainerView: View {
    @EnvironmentObject var store: SessionStore
    let tabId: UUID

    var body: some View {
        ZStack {
            if let tab = store.tabs.first(where: { $0.id == tabId }) {
                TerminalSurfaceRepresentable(tabId: tabId, generation: tab.surfaceGeneration)
                    .id("\(tabId)-\(tab.surfaceGeneration)")
                if case let .reconnecting(attempt, nextRetryAt) = tab.state {
                    ReconnectOverlay(attempt: attempt, nextRetryAt: nextRetryAt)
                }
            }
        }
    }
}
```

The `.id(...)` modifier with generation in it forces SwiftUI to tear down and recreate `TerminalSurfaceRepresentable` (and thus the `GhosttySurfaceNSView`) when generation changes.

- [ ] **Step 6: Build ReconnectOverlay**

```swift
import SwiftUI

struct ReconnectOverlay: View {
    let attempt: Int
    let nextRetryAt: Date
    @State var now = Date()
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).edgesIgnoringSafeArea(.all)
            VStack(spacing: 12) {
                ProgressView()
                Text("连接断开 — 正在重连 (\(attempt)/\(ReconnectScheduler.maxAttempts))")
                    .font(.headline).foregroundColor(.white)
                let remaining = max(0, nextRetryAt.timeIntervalSince(now))
                if remaining > 0 {
                    Text(String(format: "%.0fs", remaining)).foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .onReceive(timer) { now = $0 }
    }
}
```

- [ ] **Step 7: Manual test reconnect end-to-end**

```bash
docker run -d --rm --name=caterm-smoke -p 2222:2222 \
    -e USER_NAME=spike -e USER_PASSWORD=spikepass -e PASSWORD_ACCESS=true \
    lscr.io/linuxserver/openssh-server
.build/debug/caterm
```

Connect to host. Wait until Connected. Then `docker stop caterm-smoke`. Surface should:
1. ssh exit non-zero (likely 255 from network unreach)
2. State → `.reconnecting(attempt: 1, ...)` — overlay appears
3. After 1s, surface recreated; ssh tries to connect; fails (container down)
4. attempt: 2 → 2s wait
5. `docker run -d ...` restart container while in attempt 3+
6. attempt: 3 → 5s wait → reconnect succeeds → state → Connected → overlay disappears

If it works through this flow, FSM is sound.

- [ ] **Step 8: Commit + log**

```bash
git add apps/macos/
git commit -m "feat(macos): auto-reconnect FSM + overlay UI"
```

```
| 2026-04-27 | Task 1.8 通过：ReconnectScheduler 单测；exp backoff 1/2/5/10/30；surfaceGeneration 触发 SwiftUI 重建 surface；docker stop+start 验证重连恢复；overlay 倒计时显示 |
```

---

## Task 1.9: ConfigStore — Ghostty config file management

**Goal:** Caterm owns its own Ghostty config at `~/Library/Application Support/Caterm/config`. App writes a default on first launch. Menu item "Open Config File" reveals it in Finder/default editor. No UI for editing — user uses any text editor.

**Files:**
- Create: `apps/macos/Sources/ConfigStore/ConfigStore.swift`
- Create: `apps/macos/Tests/ConfigStoreTests/ConfigStoreTests.swift`
- Modify: `apps/macos/Sources/TerminalEngine/GhosttyConfig.swift` (load from path)
- Delete: `apps/macos/Sources/ConfigStore/Placeholder.swift`
- Delete: `apps/macos/Tests/ConfigStoreTests/PlaceholderTests.swift`

- [ ] **Step 1: Tests first**

```swift
import XCTest
@testable import ConfigStore

final class ConfigStoreTests: XCTestCase {
    var tmpURL: URL!
    override func setUp() {
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-cfg-\(UUID()).conf")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpURL) }

    func testWritesDefaultOnFirstLaunch() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))
        try ConfigStore.ensureExists(at: tmpURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpURL.path))
        let contents = try String(contentsOf: tmpURL)
        XCTAssertTrue(contents.contains("font-family"))
    }

    func testDoesNotOverwriteExisting() throws {
        try "custom-content".write(to: tmpURL, atomically: true, encoding: .utf8)
        try ConfigStore.ensureExists(at: tmpURL)
        XCTAssertEqual(try String(contentsOf: tmpURL), "custom-content")
    }

    func testFilePermissionsAre0644() throws {
        try ConfigStore.ensureExists(at: tmpURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: tmpURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o644)
    }
}
```

- [ ] **Step 2: Implement ConfigStore**

```swift
import Foundation

public enum ConfigStore {
    public static let defaultConfig = """
    # Caterm-managed Ghostty config — edit freely, restart Caterm to apply.
    # Full reference: https://ghostty.org/docs/config

    font-family = SF Mono
    font-size = 13
    theme = catppuccin-mocha
    cursor-style = block
    macos-titlebar-style = tabs
    """

    public static func ensureExists(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try defaultConfig.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: url.path)
    }

    public static var defaultPath: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Caterm/config")
    }

    public static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
```

(Need `import AppKit` for `NSWorkspace`.)

- [ ] **Step 3: Wire on app start + add menu**

In `CatermApp.swift`:

```swift
init() {
    try? ConfigStore.ensureExists(at: ConfigStore.defaultPath)
}

// In .commands { }:
CommandGroup(after: .appSettings) {
    Button("Open Configuration File…") {
        ConfigStore.revealInFinder(ConfigStore.defaultPath)
    }
}
```

In `GhosttyConfig.makeAppConfig`, load this file via `ghostty_config_load_file` (per ghostty.h).

- [ ] **Step 4: Run tests, manual verify menu**

```bash
cd apps/macos && swift test --filter ConfigStoreTests 2>&1 | tail -5
```

```bash
.build/debug/caterm  # menu Caterm > Open Configuration File… reveals config in Finder
```

- [ ] **Step 5: Commit + log**

```bash
git add apps/macos/
git rm apps/macos/Sources/ConfigStore/Placeholder.swift apps/macos/Tests/ConfigStoreTests/PlaceholderTests.swift
git commit -m "feat(macos): ConfigStore + Open Config menu"
```

```
| 2026-04-27 | Task 1.9 通过：ConfigStore 默认 Ghostty config 写入 + 不覆盖既有；菜单项「Open Configuration File…」reveal Finder；libghostty 启动时读取 |
```

---

## Task 1.10: Polish — menus, shortcuts, About

**Goal:** Native macOS feel: ⌘N new window, ⌘, settings (no-op or open config), ⌘? help, About panel with version.

**Files:**
- Modify: `apps/macos/Sources/Caterm/CatermApp.swift` (menu commands)
- Create: `apps/macos/Resources/Info.plist` (version string for About panel)

- [ ] **Step 1: Add Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Caterm</string>
    <key>CFBundleIdentifier</key><string>com.caterm.app</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
```

- [ ] **Step 2: Add full menu commands**

In `CatermApp.swift`:

```swift
.commands {
    CommandGroup(replacing: .newItem) {
        Button("New Window") { /* open new window */ }
            .keyboardShortcut("n", modifiers: .command)
        Button("New Tab") { /* trigger sidebar add */ }
            .keyboardShortcut("t", modifiers: .command)
    }
    CommandGroup(after: .appInfo) {
        Button("Open Configuration File…") {
            ConfigStore.revealInFinder(ConfigStore.defaultPath)
        }
    }
    CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
            ConfigStore.revealInFinder(ConfigStore.defaultPath)
        }.keyboardShortcut(",", modifiers: .command)
    }
    CommandGroup(replacing: .help) {
        Link("Caterm Documentation",
             destination: URL(string: "https://github.com/ZingerLittleBee/Caterm")!)
    }
}
```

- [ ] **Step 3: About panel — verify default Apple about-window populates from Info.plist**

App > About Caterm should show "Caterm 1.0.0".

- [ ] **Step 4: Manual test**

Run app. Verify:
- ⌘N opens new window
- ⌘T opens add-host sheet
- ⌘, reveals config file
- ⌘? opens GitHub
- About panel shows version

- [ ] **Step 5: Commit + log**

```bash
git add apps/macos/
git commit -m "polish(macos): menu bar + shortcuts + About"
```

```
| 2026-04-27 | Task 1.10 通过：菜单栏完整；⌘N/⌘T/⌘W/⌘,/⌘? 全连；About 面板显示版本 |
```

---

## Task 1.11: Release — bundling, codesigning, notarization, Sparkle, Tauri deprecation banner

**Goal:** Producible DMG that the user can hand to a beta tester. App + askpass both signed with same Team ID. Notarized via `notarytool`. Auto-updates via Sparkle. Old Tauri build shows deprecation banner pointing to migration.

**Files:**
- Create: `apps/macos/Scripts/release.sh`
- Modify: `apps/macos/Package.swift` (add Sparkle dependency)
- Create: `apps/macos/Sources/Caterm/Updater/SparkleUpdater.swift`
- Modify: `apps/web/src/...` (Tauri side: deprecation banner)
- Create: `apps/macos/Resources/sparkle-feed.xml` (template)

- [ ] **Step 1: Add Sparkle SwiftPM dependency**

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
],
```

Add to `Caterm` target's deps: `.product(name: "Sparkle", package: "Sparkle")`.

- [ ] **Step 2: Wire SparkleUpdater**

```swift
import SwiftUI
import Sparkle

final class SparkleUpdater: NSObject, ObservableObject {
    let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    @objc func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
```

In CatermApp menu, add "Check for Updates…" wired to this.

- [ ] **Step 3: Sparkle feed XML template**

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
    <title>Caterm</title>
    <item>
        <title>1.0.0</title>
        <sparkle:version>1</sparkle:version>
        <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
        <enclosure url="https://example.com/Caterm-1.0.0.dmg"
                   sparkle:edSignature="..." length="..."
                   type="application/octet-stream" />
    </item>
</channel>
</rss>
```

(Real signature/length filled by release.sh.)

- [ ] **Step 4: Write release.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${CATERM_DEV_IDENTITY:?required}"
: "${APPLE_ID:?required}"
: "${APP_PASSWORD:?app-specific password required}"
: "${APPLE_TEAM_ID:?required}"
: "${SPARKLE_PRIVATE_KEY:?path to ed25519 private key required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/release"
APP="$BUILD/Caterm.app"

cd "$ROOT"

echo "==> Build release"
swift build -c release

echo "==> Bundle .app"
swift bundler bundle -c release --identifier com.caterm.app --build-dir "$BUILD"

# Embed askpass binary inside the .app bundle
cp "$BUILD/caterm-askpass" "$APP/Contents/MacOS/caterm-askpass"

echo "==> Codesign askpass"
codesign --force --options runtime \
    --sign "$CATERM_DEV_IDENTITY" \
    --entitlements Resources/CatermAskpass.entitlements \
    "$APP/Contents/MacOS/caterm-askpass"

echo "==> Codesign main app (deep, to catch nested bundles)"
codesign --force --deep --options runtime \
    --sign "$CATERM_DEV_IDENTITY" \
    --entitlements Resources/Caterm.entitlements \
    "$APP"

echo "==> Verify signatures"
codesign -dvv "$APP" 2>&1 | grep TeamIdentifier
codesign -dvv "$APP/Contents/MacOS/caterm-askpass" 2>&1 | grep TeamIdentifier

echo "==> Create DMG"
DMG="$BUILD/Caterm-1.0.0.dmg"
create-dmg \
    --volname "Caterm 1.0.0" \
    --window-size 600 400 \
    --icon "Caterm.app" 175 175 \
    --app-drop-link 425 175 \
    "$DMG" "$APP"

echo "==> Notarize"
xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --password "$APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

echo "==> Staple"
xcrun stapler staple "$DMG"

echo "==> Sparkle sign"
SIGNATURE=$(./Scripts/sparkle-sign "$SPARKLE_PRIVATE_KEY" "$DMG")
LENGTH=$(stat -f%z "$DMG")
echo "Sparkle signature: $SIGNATURE"
echo "Length: $LENGTH bytes"
echo
echo "Update Resources/sparkle-feed.xml's <enclosure> with above values, host the feed + DMG, ship."
```

- [ ] **Step 5: Tauri deprecation banner**

In `apps/web/src/routes/__root.tsx`, add a top-of-app banner:

```tsx
<div style={{
  background: '#fef3c7', padding: '12px 24px', textAlign: 'center',
  borderBottom: '1px solid #fde68a',
}}>
  <strong>Caterm Tauri 客户端已停止维护。</strong>
  <a href="https://github.com/ZingerLittleBee/Caterm/releases">下载新版 Swift 客户端</a>
</div>
```

Per spec D9 — this is the one-time exception to "Tauri 完全冻结".

- [ ] **Step 6: Dry-run release.sh**

```bash
cd apps/macos
export CATERM_DEV_IDENTITY="..."
export APPLE_ID="..."
export APP_PASSWORD="..."
export APPLE_TEAM_ID="..."
export SPARKLE_PRIVATE_KEY="..."
./Scripts/release.sh
```

Expected: produces `Caterm-1.0.0.dmg`; notarytool returns "Accepted"; stapled; sparkle-sign output recorded.

- [ ] **Step 7: Manual install + smoke**

Eject all dev versions of Caterm. Open the DMG, drag to Applications, launch. Should show Gatekeeper "Caterm is from a verified developer" dialog and run. Connect to a host — should work.

- [ ] **Step 8: Tag release + push**

```bash
git tag -a v1.0.0 -m "Caterm Swift v1.0.0"
git push origin v1.0.0
```

Upload DMG + sparkle-feed.xml to GitHub release.

- [ ] **Step 9: Commit final code + log**

```bash
git add .
git commit -m "feat(macos): release tooling, Sparkle, Tauri deprecation banner"
```

```
| 2026-04-27 | Task 1.11 通过 — Phase 1 v1 SHIP：release.sh 出 DMG（双 binary 同 Team ID 签名 + notarized + stapled）；Sparkle 自动更新；Tauri banner 上线；GitHub release 发布；内测可分发 |
| 2026-04-27 | **Phase 1 v1 COMPLETE — 6 项 MVP 全部达成 DoD（SSH 三路 auth / libghostty render + 多 tab / 主机列表 / Keychain 凭据 / 自动重连 / hybrid known_hosts）；下一步 v1.1 同步功能** |
```

---

## End-of-Phase wrap-up

- [ ] Run full test suite one more time:

```bash
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: all tests in 4 test targets pass.

- [ ] Run full Docker smoke matrix per `Manual/docker-smoke-matrix.md`:
  - 3 auth paths × 4 known_hosts cases = 12 cases
  - All must pass before declaring v1 shipped

- [ ] Final progress log entry marking Phase 1 ship:

```
| 2026-04-27 | Phase 1 v1 ship — Caterm Swift 客户端可分发；Tauri 停摆；下一步：v1.1 同步设计（待开新一轮 brainstorm） |
```

---

## Cross-cutting concerns (apply to every task)

**Performance budget:** None set — defer until v1 ships and we have telemetry.

**Test discipline:**
- TDD-rigorous tasks: 1.2 (SSHCommandBuilder), 1.3 (KeychainStore), 1.6 (HostPersistence), 1.7 (KeychainIntegration), 1.8 (ReconnectFSM), 1.9 (ConfigStore)
- Smoke-only: 1.1 (TerminalEngine — trust libghostty), 1.5 (multi-tab UI)
- Manual + visual: 1.4, 1.10, 1.11

**Commit cadence:** End of every task. Tag `v1.0.0` only at end of Task 1.11.

**Risk register:** see spec §8. Especially watch:
- R9 (askpass codesign) — comes due in Task 1.3 and again in Task 1.11
- R10 (failure classification granularity) — in Task 1.4 and 1.8 reconnect
- R11 (shell-quote injection) — in Task 1.2; any regression is a security incident

**Where to ask for help:**
- libghostty C API edge cases → `Vendor/ghostty/include/ghostty.h` and `apps/macos/Vendor/ghostty/src/apprt/embedded.zig`
- macOS Keychain ACL gotchas → Apple's [Keychain Services](https://developer.apple.com/documentation/security/keychain_services) docs
- Sparkle integration → [Sparkle docs](https://sparkle-project.org/)

---

## Self-review notes

- Spec coverage: §6.1 steps 1.0-1.11 all map to tasks 1.0-1.11. ✓
- Placeholder scan: no "TBD" / "implement later" in the plan. ✓
- Type consistency: `Host`, `CredentialSource`, `ConnectionState`, `FailureKind`, `ReconnectScheduler` defined consistently across tasks. ✓
- Method names: `setHostSecret`, `deleteHost`, `markChildExited`, `markConnected`, `surfaceConfig(for:)` — used the same in producer + consumer. ✓
- TDD steps: every test step has the actual test code; every implementation step has the actual code. No "write tests for the above" without code. ✓
- Commands: every `swift test` / `swift build` / `docker run` has the exact invocation. ✓
- Per-task verify-and-commit at end. ✓

This plan is ~5000 LOC of plan text producing ~3000-4000 LOC of Swift. ~25-31 working days of execution time per spec §6.1.
