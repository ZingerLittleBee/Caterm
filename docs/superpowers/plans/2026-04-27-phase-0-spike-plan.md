# Phase 0 Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove that `swift-nio-ssh + libghostty + Swift/SwiftUI` is a viable foundation for the macOS rebuild by hitting all six Spike acceptance criteria S1-S6 in 3-5 days. **Code is throwaway.**

**Architecture:** Single SwiftPM executable in `apps/macos/`. SSH I/O runs on swift-nio-ssh's event loop; terminal rendering runs in libghostty hosted by an `NSViewRepresentable`. Bytes flow NIO→MainActor→libghostty for stdout, MainActor→NIO for keyboard input. No abstractions, no tests — just enough code to demonstrate the link works.

**Tech Stack:**
- Swift 5.10+ (Xcode 15.4 toolchain), macOS 14+
- SwiftPM (no `.xcodeproj`)
- swift-nio-ssh 0.10+
- libghostty (`Vendor/ghostty` submodule, built via Zig 0.13+ → `.xcframework` → SwiftPM `binaryTarget`)
- SwiftUI + AppKit (`NSViewRepresentable` for libghostty surface)

**Spec reference:** `docs/superpowers/specs/2026-04-27-tauri-to-swift-migration-design.md` §5

**Progress tracker:** `docs/superpowers/plans/2026-04-27-swift-migration-progress.md` (append a 1-line log per day per spec §5.3)

---

## Spike Discipline (read before starting)

Per spec §5.3, while in Phase 0:

- **No abstractions** — no ViewModels, no protocols, no DI containers, no MVVM
- **No tests** — verification is visual against S1-S6
- **No打磨** — no menus, no preferences, no shortcuts, no app icon
- **No Keychain / Sparkle / signing** — that's Phase 1
- **One window, one tab, one machine** — multi-tab is Phase 1
- **Credentials never in source** — env var or `.spike.local.json` only
- **Host key校验暂不做** — accept-all with `// TODO(step-1.2)` comment
- **End each session by appending one line to the progress file**: what you got working / what blocked you

The temptation to "do it properly" is the #1 risk to spike speed. If a step asks you to inline three properties on a struct — inline them. Refactor in Phase 1.

---

## File Structure

```
apps/macos/                              # NEW directory
├── .gitignore                           # NEW
├── Package.swift                        # NEW
├── Package.resolved                     # generated
├── Sources/
│   └── CatermSpike/                     # single executable target
│       ├── CatermSpikeApp.swift         # @main
│       ├── SpikeConfig.swift            # env / .spike.local.json loader
│       ├── TerminalView.swift           # NSViewRepresentable hosting libghostty
│       ├── GhosttyBridge.swift          # thin libghostty C-API wrapper
│       └── SSHSpike.swift               # NIOSSH connect + I/O glue
├── Vendor/
│   └── ghostty/                         # git submodule, pinned commit
├── Scripts/
│   └── build-libghostty.sh              # zig build → .xcframework
├── Frameworks/                          # build output, gitignored
│   └── GhosttyKit.xcframework           # produced by build script
├── module.modulemap                     # C interop for libghostty headers
└── .spike.local.json                    # gitignored, user-provided creds
```

**Why this shape:**
- Single target `CatermSpike` keeps everything in one binary; we'll split into modules in Phase 1
- `Vendor/ghostty` is a submodule pinned to a known-good commit (per spec R8 mitigation)
- `Frameworks/` is build output, never committed

---

## Prerequisites

Before starting Task 1, verify on your dev machine:

- [ ] **Swift toolchain ≥ 5.10**: `swift --version` → `Apple Swift version 5.10` or newer
- [ ] **Zig ≥ 0.13**: `zig version` → `0.13.0` or newer (install: `brew install zig`)
- [ ] **macOS ≥ 14**: `sw_vers -productVersion` → `14.x` or newer
- [ ] **A reachable Linux/macOS machine for SSH testing**, with:
  - SSH server enabled
  - A user account with password auth (key auth is Phase 1)
  - Connectivity from your dev machine
- [ ] You can `ssh user@host` to it from a regular terminal first — confirms network/firewall before adding code variables to debug

If any prerequisite fails, stop and resolve before writing code. The spike has no headroom for environment troubleshooting.

---

## Task 1: Bootstrap SwiftPM Project

**Goal:** S1 part 1 — empty SwiftUI app builds and runs.

**Files:**
- Create: `apps/macos/.gitignore`
- Create: `apps/macos/Package.swift`
- Create: `apps/macos/Sources/CatermSpike/CatermSpikeApp.swift`

- [ ] **Step 1.1: Create directory and gitignore**

```bash
mkdir -p apps/macos/Sources/CatermSpike
cd apps/macos
```

Create `apps/macos/.gitignore`:

```gitignore
.build/
.swiftpm/
Package.resolved
Frameworks/
*.xcframework
.spike.local.json
DerivedData/
xcuserdata/
```

- [ ] **Step 1.2: Write Package.swift**

Create `apps/macos/Package.swift`:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CatermSpike",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CatermSpike", targets: ["CatermSpike"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "CatermSpike",
            path: "Sources/CatermSpike"
        )
    ]
)
```

- [ ] **Step 1.3: Write minimal SwiftUI app**

Create `apps/macos/Sources/CatermSpike/CatermSpikeApp.swift`:

```swift
import SwiftUI

@main
struct CatermSpikeApp: App {
    var body: some Scene {
        WindowGroup("Caterm Spike") {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}

struct ContentView: View {
    var body: some View {
        Text("Spike alive")
            .font(.system(size: 24, design: .monospaced))
            .padding()
    }
}
```

- [ ] **Step 1.4: Build and run**

Run: `cd apps/macos && swift build`
Expected: `Build complete!` (no errors)

Run: `swift run CatermSpike`
Expected: A window appears showing "Spike alive" in monospace. Close it with ⌘Q.

- [ ] **Step 1.5: Commit**

```bash
cd /Users/zingerbee/Documents/Caterm
git add apps/macos/
git commit -m "spike(phase-0): bootstrap SwiftPM macOS app shell"
```

---

## Task 2: Vendor libghostty + Build Script

**Goal:** S1 part 2 — libghostty.xcframework produced and linkable.

**Files:**
- Create: `apps/macos/Scripts/build-libghostty.sh`
- Create: `apps/macos/Vendor/ghostty/` (git submodule)
- Modify: `apps/macos/Package.swift`

- [ ] **Step 2.1: Add Ghostty as submodule, pinned**

Run:

```bash
cd /Users/zingerbee/Documents/Caterm
git submodule add https://github.com/ghostty-org/ghostty apps/macos/Vendor/ghostty
cd apps/macos/Vendor/ghostty
git checkout v1.0.1   # or latest stable tag at time of execution; record exact commit in progress log
cd /Users/zingerbee/Documents/Caterm
git add .gitmodules apps/macos/Vendor/ghostty
```

Note: if `v1.0.1` tag doesn't exist or you want a newer one, use `git tag -l | sort -V | tail -5` inside `Vendor/ghostty` to pick. **Record the exact commit hash you used in the progress file**, per spec R8.

- [ ] **Step 2.2: Write build script**

Create `apps/macos/Scripts/build-libghostty.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

GHOSTTY_DIR="$ROOT/Vendor/ghostty"
OUT_DIR="$ROOT/Frameworks"
XCFRAMEWORK="$OUT_DIR/GhosttyKit.xcframework"

if [ ! -d "$GHOSTTY_DIR" ]; then
    echo "Error: $GHOSTTY_DIR not found. Did you init submodules?"
    exit 1
fi

echo "==> Building libghostty (this can take 5-10 minutes first time)"
cd "$GHOSTTY_DIR"

# Ghostty's build target for the macOS xcframework. Exact target name may vary
# by version — check 'zig build --help' if this fails.
zig build -Dapp-runtime=none -Doptimize=ReleaseFast macos-xcframework

mkdir -p "$OUT_DIR"
rm -rf "$XCFRAMEWORK"

# Output location varies; common path:
SRC="$GHOSTTY_DIR/zig-out/GhosttyKit.xcframework"
if [ ! -d "$SRC" ]; then
    echo "Error: expected xcframework at $SRC, not found."
    echo "Inspect $GHOSTTY_DIR/zig-out/ to find actual output and update this script."
    exit 1
fi

cp -R "$SRC" "$XCFRAMEWORK"
echo "==> $XCFRAMEWORK ready"
```

Make it executable:

```bash
chmod +x apps/macos/Scripts/build-libghostty.sh
```

**Note:** Ghostty's exact `zig build` target/flags may evolve. If the script fails, **read Ghostty's own `build.zig` and `README` for the current xcframework target name**, then update the script. Don't guess; record what you found in the progress file.

- [ ] **Step 2.3: Run the build script**

Run: `apps/macos/Scripts/build-libghostty.sh`
Expected: After 5-10 minutes, `apps/macos/Frameworks/GhosttyKit.xcframework/` exists with at minimum:
- `Info.plist`
- `macos-arm64/GhosttyKit.framework/` (or similar arch dir)

If the script fails:
- The most likely cause is Ghostty changed its build target. Check `zig build --help` inside `Vendor/ghostty` and update `Scripts/build-libghostty.sh` accordingly.
- Document the fix in `apps/macos/Scripts/README.md` (create it) so the next person doesn't repeat the trial-and-error.

- [ ] **Step 2.4: Wire xcframework into Package.swift**

Replace `apps/macos/Package.swift` content:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CatermSpike",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CatermSpike", targets: ["CatermSpike"])
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "CatermSpike",
            dependencies: ["GhosttyKit"],
            path: "Sources/CatermSpike"
        )
    ]
)
```

- [ ] **Step 2.5: Verify Swift can link the framework**

Open `apps/macos/Sources/CatermSpike/CatermSpikeApp.swift` and add at the top:

```swift
import GhosttyKit
```

Run: `cd apps/macos && swift build`
Expected: builds without "no such module 'GhosttyKit'" error.

If it fails, the framework name inside `Info.plist` may differ. Run `cat Frameworks/GhosttyKit.xcframework/Info.plist | grep -A1 LibraryIdentifier` and adjust `name` in `binaryTarget`.

- [ ] **Step 2.6: Commit**

```bash
cd /Users/zingerbee/Documents/Caterm
git add apps/macos/Scripts/ apps/macos/Package.swift apps/macos/Sources/CatermSpike/CatermSpikeApp.swift .gitmodules
git commit -m "spike(phase-0): vendor Ghostty submodule and build libghostty xcframework"
```

**Append to progress file (`docs/superpowers/plans/2026-04-27-swift-migration-progress.md`):**

```
| YYYY-MM-DD | S1 通过：libghostty.xcframework 链接成功；Ghostty pinned at <commit hash> |
```

---

## Task 3: Render Hardcoded Bytes via libghostty (S2)

**Goal:** Hardcoded `"Hello\r\n"` is parsed by libghostty and visible on screen in the SwiftUI window.

**Files:**
- Create: `apps/macos/Sources/CatermSpike/GhosttyBridge.swift`
- Create: `apps/macos/Sources/CatermSpike/TerminalView.swift`
- Modify: `apps/macos/Sources/CatermSpike/CatermSpikeApp.swift`

> **Important:** libghostty's exact public C API surface is the #1 unknown for this spike (spec R1). Before writing code, read:
> - `Vendor/ghostty/include/ghostty.h` (the public C header)
> - `Vendor/ghostty/macos/Sources/Ghostty/` (Swift code for the official Ghostty.app — best reference for how to call the C API)
>
> The function names, init configs, and callback shapes below are **placeholders based on the public API as of the design's writing**. If they don't match the version you pinned in Task 2, update accordingly. Note any deviations in the progress file — that's data for Phase 1.

- [ ] **Step 3.1: Write GhosttyBridge.swift**

Create `apps/macos/Sources/CatermSpike/GhosttyBridge.swift`:

```swift
import AppKit
import GhosttyKit

/// Thin wrapper over libghostty surface lifecycle. Spike code: no abstractions,
/// no protocols, just enough to drive a single surface.
final class GhosttyBridge {
    private var app: ghostty_app_t?
    private var surface: ghostty_surface_t?

    /// Called by libghostty when it wants to send bytes back (e.g., after a
    /// keypress). For the spike, parent code sets this closure to forward bytes
    /// to SSH stdin. Default no-op so render-only S2 still works.
    var onWriteRequest: (Data) -> Void = { _ in }

    init() throws {
        var appConfig = ghostty_config_new()
        // For the spike we don't load a user config file. Defaults are fine.

        var appOpts = ghostty_app_config_s()
        appOpts.userdata = Unmanaged.passUnretained(self).toOpaque()
        appOpts.write_cb = { userdata, data, len in
            guard let userdata = userdata else { return }
            let bridge = Unmanaged<GhosttyBridge>.fromOpaque(userdata).takeUnretainedValue()
            let buffer = UnsafeBufferPointer(start: data, count: len)
            bridge.onWriteRequest(Data(buffer: buffer))
        }
        // Other callbacks (set_title, etc.) intentionally left default for spike.

        guard let app = ghostty_app_new(&appOpts, appConfig) else {
            throw NSError(domain: "GhosttyBridge", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "ghostty_app_new failed"])
        }
        self.app = app
    }

    /// Create the surface bound to a host NSView. Caller passes its layer.
    func createSurface(forView view: NSView) throws {
        guard let app = self.app else { return }

        var surfOpts = ghostty_surface_config_s()
        surfOpts.userdata = Unmanaged.passUnretained(self).toOpaque()
        surfOpts.nsview = Unmanaged.passUnretained(view).toOpaque()
        surfOpts.scale_factor = view.window?.backingScaleFactor ?? 2.0

        guard let surface = ghostty_surface_new(app, &surfOpts) else {
            throw NSError(domain: "GhosttyBridge", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "ghostty_surface_new failed"])
        }
        self.surface = surface
    }

    /// Feed inbound bytes (e.g., remote stdout) to libghostty for VT parsing
    /// and rendering. Must be called on MainActor.
    func feed(_ data: Data) {
        guard let surface = self.surface else { return }
        data.withUnsafeBytes { raw in
            ghostty_surface_write_data(surface, raw.baseAddress, raw.count)
        }
    }

    /// Tell libghostty about a new size in pixels.
    func resize(width: Double, height: Double) {
        guard let surface = self.surface else { return }
        ghostty_surface_set_size(surface, UInt32(width), UInt32(height))
    }

    func handleKeyDown(_ event: NSEvent) {
        guard let surface = self.surface else { return }
        // In the spike, just forward characters; full key translation is
        // step 5's problem.
        guard let chars = event.characters else { return }
        chars.utf8.withContiguousStorageIfAvailable { buf in
            ghostty_surface_text(surface, buf.baseAddress, buf.count)
        }
    }

    deinit {
        if let s = surface { ghostty_surface_free(s) }
        if let a = app { ghostty_app_free(a) }
    }
}
```

> If any of the `ghostty_*` symbols above don't exist in your pinned version, **read `ghostty.h` and adjust**. The point of the spike is to find out — not to assume.

- [ ] **Step 3.2: Write TerminalView.swift**

Create `apps/macos/Sources/CatermSpike/TerminalView.swift`:

```swift
import AppKit
import SwiftUI

/// SwiftUI wrapper that hosts libghostty's surface inside an NSView.
struct TerminalView: NSViewRepresentable {
    let bridge: GhosttyBridge

    func makeNSView(context: Context) -> NSView {
        let view = TerminalNSView()
        view.bridge = bridge
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class TerminalNSView: NSView {
    var bridge: GhosttyBridge?
    private var didCreateSurface = false

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didCreateSurface, window != nil, let bridge else { return }
        do {
            try bridge.createSurface(forView: self)
            didCreateSurface = true
            window?.makeFirstResponder(self)
        } catch {
            print("Failed to create surface: \(error)")
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        bridge?.resize(width: Double(newSize.width), height: Double(newSize.height))
    }

    override func keyDown(with event: NSEvent) {
        bridge?.handleKeyDown(event)
    }
}
```

- [ ] **Step 3.3: Hook bridge into the app and feed test bytes**

Replace `apps/macos/Sources/CatermSpike/CatermSpikeApp.swift`:

```swift
import GhosttyKit
import SwiftUI

@main
struct CatermSpikeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Caterm Spike") {
            Group {
                if let bridge = state.bridge {
                    TerminalView(bridge: bridge)
                } else if let err = state.error {
                    Text("Bridge init failed: \(err)").padding()
                } else {
                    Text("Initializing...").padding()
                }
            }
            .frame(minWidth: 800, minHeight: 500)
            .task { state.start() }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var bridge: GhosttyBridge?
    @Published var error: String?

    func start() {
        guard bridge == nil, error == nil else { return }
        do {
            let b = try GhosttyBridge()
            self.bridge = b
            // Feed a hardcoded test string after a small delay so the surface
            // exists by the time bytes arrive.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                let hello = "Hello, libghostty!\r\nLine 2\r\n".data(using: .utf8)!
                b.feed(hello)
            }
        } catch {
            self.error = "\(error)"
        }
    }
}
```

- [ ] **Step 3.4: Build and run**

Run: `cd apps/macos && swift build && swift run CatermSpike`
Expected: A window opens. After ~500ms you see:

```
Hello, libghostty!
Line 2
```

rendered by libghostty (note: libghostty's font, not SwiftUI's).

If the window opens but stays blank: surface likely didn't bind to the view. Check console output for errors. Most common cause is `ghostty_surface_new` returning NULL — try varying the `nsview` userdata pointer or checking `ghostty.h` for required config fields.

If you crash inside libghostty: the C API shape probably differs from the placeholders. Read `ghostty.h` and Ghostty's own macos sources to find the right shape.

- [ ] **Step 3.5: Commit**

```bash
cd /Users/zingerbee/Documents/Caterm
git add apps/macos/Sources/
git commit -m "spike(phase-0): render hardcoded bytes through libghostty surface (S2)"
```

**Append to progress file**: `S2 通过：硬编码字节渲染 OK` (or describe the API shape adjustments you needed to make).

---

## Task 4: Spike Credentials Loader

**Goal:** Connection parameters loaded from env or `.spike.local.json`. No secrets in source.

**Files:**
- Create: `apps/macos/Sources/CatermSpike/SpikeConfig.swift`
- Update: `apps/macos/.spike.local.json.example` (committed example)

- [ ] **Step 4.1: Write SpikeConfig.swift**

Create `apps/macos/Sources/CatermSpike/SpikeConfig.swift`:

```swift
import Foundation

struct SpikeConfig: Codable {
    let host: String
    let port: Int
    let user: String
    let password: String

    static func load() throws -> SpikeConfig {
        // Priority 1: env vars
        let env = ProcessInfo.processInfo.environment
        if let h = env["CATERM_SPIKE_HOST"],
           let u = env["CATERM_SPIKE_USER"],
           let p = env["CATERM_SPIKE_PASSWORD"] {
            let port = Int(env["CATERM_SPIKE_PORT"] ?? "22") ?? 22
            return SpikeConfig(host: h, port: port, user: u, password: p)
        }

        // Priority 2: .spike.local.json next to Package.swift
        let url = URL(fileURLWithPath: "apps/macos/.spike.local.json",
                      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(SpikeConfig.self, from: data)
        }

        throw NSError(domain: "SpikeConfig", code: 1, userInfo: [
            NSLocalizedDescriptionKey:
                "No config found. Set CATERM_SPIKE_HOST/USER/PASSWORD env vars or create apps/macos/.spike.local.json"
        ])
    }
}
```

- [ ] **Step 4.2: Write committed example file**

Create `apps/macos/.spike.local.json.example`:

```json
{
    "host": "your-host.example.com",
    "port": 22,
    "user": "your-username",
    "password": "your-password"
}
```

- [ ] **Step 4.3: Verify .spike.local.json is gitignored**

Run: `cd /Users/zingerbee/Documents/Caterm && git check-ignore -v apps/macos/.spike.local.json`
Expected: output shows `apps/macos/.gitignore:N:.spike.local.json` (some line). If it prints nothing, the rule is missing — re-check Task 1's `.gitignore`.

- [ ] **Step 4.4: Smoke test the loader**

Temporarily, in `AppState.start()`, add at the top:

```swift
do {
    let cfg = try SpikeConfig.load()
    print("[spike] loaded config for \(cfg.user)@\(cfg.host):\(cfg.port)")
} catch {
    print("[spike] config error: \(error)")
}
```

Set env vars and run:

```bash
cd /Users/zingerbee/Documents/Caterm
CATERM_SPIKE_HOST=your-host CATERM_SPIKE_USER=you CATERM_SPIKE_PASSWORD=secret \
    swift run --package-path apps/macos CatermSpike
```

Expected console output: `[spike] loaded config for you@your-host:22` (password not printed).

Remove the temporary print after verifying.

- [ ] **Step 4.5: Commit**

```bash
cd /Users/zingerbee/Documents/Caterm
git add apps/macos/Sources/CatermSpike/SpikeConfig.swift apps/macos/.spike.local.json.example
git commit -m "spike(phase-0): add gitignored credential loader (env + .spike.local.json)"
```

---

## Task 5: NIOSSH Connect → stdout to Console (S3)

**Goal:** Open SSH session, request PTY + shell, log received stdout bytes to console. No libghostty integration yet.

**Files:**
- Modify: `apps/macos/Package.swift` (add swift-nio-ssh)
- Create: `apps/macos/Sources/CatermSpike/SSHSpike.swift`
- Modify: `apps/macos/Sources/CatermSpike/CatermSpikeApp.swift`

- [ ] **Step 5.1: Add swift-nio-ssh dependency**

Replace `apps/macos/Package.swift`:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CatermSpike",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CatermSpike", targets: ["CatermSpike"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.10.0")
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "CatermSpike",
            dependencies: [
                "GhosttyKit",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh")
            ],
            path: "Sources/CatermSpike"
        )
    ]
)
```

Run: `cd apps/macos && swift package resolve` → expected: dependencies resolved, no errors.

- [ ] **Step 5.2: Write SSHSpike.swift**

Create `apps/macos/Sources/CatermSpike/SSHSpike.swift`:

```swift
import Foundation
import NIO
import NIOSSH

/// Spike-grade SSH connection: connect → auth (password) → open channel →
/// request PTY+shell → forward stdout via callback.
///
/// Production code (Phase 1) will refactor heavily. Read for shape, not style.
final class SSHSpike {
    private let group: EventLoopGroup
    private var channel: Channel?
    private var sessionChannel: Channel?

    /// Called from NIO event loop when stdout bytes arrive. Implementer must
    /// hop to MainActor before touching libghostty.
    var onStdout: (Data) -> Void = { _ in }

    init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func connect(config: SpikeConfig) async throws {
        // SECURITY: accept-all host key. TODO(step-1.2) replace with KnownHostStore.
        let clientConfig = SSHClientConfiguration(
            userAuthDelegate: PasswordAuthDelegate(username: config.user, password: config.password),
            serverAuthDelegate: AcceptAllHostKeysDelegate()
        )

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(role: .client(clientConfig), allocator: channel.allocator, inboundChildChannelInitializer: nil)
                ])
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        let ch = try await bootstrap.connect(host: config.host, port: config.port).get()
        self.channel = ch

        // Open a session child channel.
        let sshHandler = try await ch.pipeline.handler(type: NIOSSHHandler.self).get()
        let promise = ch.eventLoop.makePromise(of: Channel.self)
        sshHandler.createChannel(promise, channelType: .session) { [weak self] childChannel, _ in
            guard let self else { return childChannel.eventLoop.makeFailedFuture(ChannelError.alreadyClosed) }
            return self.installSessionHandlers(on: childChannel)
        }
        let session = try await promise.futureResult.get()
        self.sessionChannel = session

        // Request PTY then shell.
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([:])
        )
        try await session.triggerUserOutboundEvent(ptyRequest)

        let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        try await session.triggerUserOutboundEvent(shellRequest)
    }

    private func installSessionHandlers(on channel: Channel) -> EventLoopFuture<Void> {
        // Enable half-closure per spec §4.2 / §6.3.
        return channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
            channel.pipeline.addHandler(StdoutForwarder(spike: self))
        }
    }

    func writeStdin(_ data: Data) {
        guard let session = self.sessionChannel else { return }
        var buffer = session.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let dataMsg = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        session.eventLoop.execute {
            session.writeAndFlush(dataMsg, promise: nil)
        }
    }

    func sendWindowChange(cols: Int, rows: Int) {
        guard let session = self.sessionChannel else { return }
        let evt = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        session.eventLoop.execute {
            session.triggerUserOutboundEvent(evt, promise: nil)
        }
    }

    func shutdown() async {
        try? await sessionChannel?.close()
        try? await channel?.close()
        try? await group.shutdownGracefully()
    }
}

// MARK: - Auth delegate

private final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let password: String
    init(username: String, password: String) {
        self.username = username
        self.password = password
    }
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.password) else {
            nextChallengePromise.succeed(nil)
            return
        }
        nextChallengePromise.succeed(.init(
            username: username,
            serviceName: "",
            offer: .password(.init(password: password))
        ))
    }
}

// MARK: - Server key delegate (SPIKE: accept-all)

private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // TODO(step-1.2): replace with KnownHostStore lookup + TOFU dialog.
        validationCompletePromise.succeed(())
    }
}

// MARK: - Stdout reader

private final class StdoutForwarder: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    weak var spike: SSHSpike?
    init(spike: SSHSpike) { self.spike = spike }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        let bytes = Data(buffer.readableBytesView)
        spike?.onStdout(bytes)
    }
}
```

> **Heads up:** swift-nio-ssh's exact API may have moved. If `SSHChannelRequestEvent.PseudoTerminalRequest` etc. don't compile, read `apple/swift-nio-ssh` README & source for the current shape. Spec §6.3 already flagged this as a known unknown. Record any deviations in the progress file.

- [ ] **Step 5.3: Wire SSH into AppState (console-only for S3)**

Modify `AppState` in `CatermSpikeApp.swift` — add SSH connection alongside existing bridge code:

```swift
@MainActor
final class AppState: ObservableObject {
    @Published var bridge: GhosttyBridge?
    @Published var error: String?

    private var ssh: SSHSpike?

    func start() {
        guard bridge == nil, error == nil else { return }
        do {
            let b = try GhosttyBridge()
            self.bridge = b

            // SSH side: connect, log stdout to console (S3 only).
            let cfg = try SpikeConfig.load()
            let ssh = SSHSpike()
            self.ssh = ssh
            ssh.onStdout = { data in
                let s = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
                print("[ssh stdout] \(s.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n"))")
            }
            Task {
                do {
                    try await ssh.connect(config: cfg)
                    print("[ssh] connected to \(cfg.user)@\(cfg.host):\(cfg.port)")
                } catch {
                    print("[ssh] connect failed: \(error)")
                }
            }
        } catch {
            self.error = "\(error)"
        }
    }
}
```

- [ ] **Step 5.4: Run and verify**

Set env vars and run:

```bash
CATERM_SPIKE_HOST=your-host CATERM_SPIKE_USER=you CATERM_SPIKE_PASSWORD=secret \
    swift run --package-path apps/macos CatermSpike
```

Expected console output (within ~3 seconds):
```
[ssh] connected to you@your-host:22
[ssh stdout] Last login: Fri Jan ...\r\n
[ssh stdout] you@host:~$
```

(The exact greeting depends on the remote system's shell setup.)

The window will still show the hardcoded "Hello, libghostty!" text — that's expected; full link comes in Task 6.

- [ ] **Step 5.5: Commit**

```bash
cd /Users/zingerbee/Documents/Caterm
git add apps/macos/Package.swift apps/macos/Package.resolved apps/macos/Sources/
git commit -m "spike(phase-0): NIOSSH connect + stdout forwarding to console (S3)"
```

**Append to progress file**: `S3 通过：NIOSSH 连接 OK，stdout 字节流到 console`. Note any swift-nio-ssh API adjustments you had to make.

---

## Task 6: Splice NIOSSH stdout → libghostty (S4)

**Goal:** Remote shell output appears in the terminal window in real time.

**Files:**
- Modify: `apps/macos/Sources/CatermSpike/CatermSpikeApp.swift`

- [ ] **Step 6.1: Forward SSH stdout to GhosttyBridge.feed**

Replace `AppState.start()`'s `ssh.onStdout` closure:

```swift
ssh.onStdout = { [weak b] data in
    Task { @MainActor in
        b?.feed(data)
    }
}
```

Also remove the temporary "Hello, libghostty!" feed in `Task @MainActor in { try? await Task.sleep ... }` — the remote shell greeting takes its place.

- [ ] **Step 6.2: Run and verify**

```bash
CATERM_SPIKE_HOST=your-host CATERM_SPIKE_USER=you CATERM_SPIKE_PASSWORD=secret \
    swift run --package-path apps/macos CatermSpike
```

Expected: Within 1-2 seconds of window opening, the remote shell's MOTD/prompt appears in the libghostty surface (not just the console). It should look like a normal terminal prompt.

If the surface stays blank but console still shows stdout: the bridge between Task `@MainActor` and `ghostty_surface_write_data` isn't reaching the surface. Add a `print("[feed] \(data.count) bytes")` inside `b?.feed` to confirm it's being called.

- [ ] **Step 6.3: Commit**

```bash
cd /Users/zingerbee/Documents/Caterm
git add apps/macos/Sources/CatermSpike/CatermSpikeApp.swift
git commit -m "spike(phase-0): wire NIOSSH stdout to libghostty surface (S4)"
```

**Append to progress file**: `S4 通过：远端 shell 输出在窗口实时显示`.

---

## Task 7: Keyboard Input → SSH stdin (S5)

**Goal:** Pressing keys in the window sends bytes to remote shell. `echo $$` works.

**Files:**
- Modify: `apps/macos/Sources/CatermSpike/CatermSpikeApp.swift`
- Modify: `apps/macos/Sources/CatermSpike/GhosttyBridge.swift`

- [ ] **Step 7.1: Wire bridge.onWriteRequest into ssh.writeStdin**

In `AppState.start()` after `self.ssh = ssh`, add:

```swift
b.onWriteRequest = { [weak ssh] data in
    ssh?.writeStdin(data)
}
```

This routes libghostty's "I have bytes for the PTY" callback (which fires when keys are pressed) into the SSH channel. `writeStdin` already hops to NIO's event loop internally.

- [ ] **Step 7.2: Run and verify**

```bash
CATERM_SPIKE_HOST=your-host CATERM_SPIKE_USER=you CATERM_SPIKE_PASSWORD=secret \
    swift run --package-path apps/macos CatermSpike
```

Click in the terminal window to focus it, then type:

```
echo hi
<Return>
echo $$
<Return>
```

Expected: You see what you typed echoed by the shell, and `echo $$` prints a process ID number. Both prove keystrokes are reaching the remote shell and the response is rendered correctly.

If keys do nothing: most likely `GhosttyBridge.handleKeyDown` isn't routing to `onWriteRequest`. The `ghostty_surface_text` call fires libghostty's write callback (set in `ghostty_app_new`); confirm with a `print` in `onWriteRequest`. If libghostty doesn't fire its write callback for plain text, you may need `ghostty_surface_key` instead — check `ghostty.h`.

- [ ] **Step 7.3: Commit**

```bash
cd /Users/zingerbee/Documents/Caterm
git add apps/macos/Sources/
git commit -m "spike(phase-0): keyboard input routed to SSH stdin (S5)"
```

**Append to progress file**: `S5 通过：键盘输入 → 远端 shell；echo $$ 工作`.

---

## Task 8: Window Resize → PTY + libghostty (S6)

**Goal:** Resizing the window updates both libghostty's layout and the remote PTY size. `stty size` reflects the new dimensions.

**Files:**
- Modify: `apps/macos/Sources/CatermSpike/TerminalView.swift`
- Modify: `apps/macos/Sources/CatermSpike/CatermSpikeApp.swift`

- [ ] **Step 8.1: Hook resize through to SSH window-change**

Update `TerminalNSView` to also notify SSH on resize. We need access to the `SSHSpike` instance — pass it through.

Replace `TerminalView.swift`:

```swift
import AppKit
import SwiftUI

struct TerminalView: NSViewRepresentable {
    let bridge: GhosttyBridge
    let onResize: (Int, Int) -> Void   // (cols, rows)

    func makeNSView(context: Context) -> NSView {
        let view = TerminalNSView()
        view.bridge = bridge
        view.onResize = onResize
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class TerminalNSView: NSView {
    var bridge: GhosttyBridge?
    var onResize: ((Int, Int) -> Void)?
    private var didCreateSurface = false

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didCreateSurface, window != nil, let bridge else { return }
        do {
            try bridge.createSurface(forView: self)
            didCreateSurface = true
            window?.makeFirstResponder(self)
            // Initial size push.
            propagateResize()
        } catch {
            print("Failed to create surface: \(error)")
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        bridge?.resize(width: Double(newSize.width), height: Double(newSize.height))
        propagateResize()
    }

    private func propagateResize() {
        // Crude cell-size estimate for the spike. Phase 1 should ask libghostty
        // for the actual cell metrics.
        let approxCellWidth: CGFloat = 8.0
        let approxCellHeight: CGFloat = 16.0
        let cols = max(1, Int(bounds.width / approxCellWidth))
        let rows = max(1, Int(bounds.height / approxCellHeight))
        onResize?(cols, rows)
    }

    override func keyDown(with event: NSEvent) {
        bridge?.handleKeyDown(event)
    }
}
```

- [ ] **Step 8.2: Wire onResize from SwiftUI to SSH**

Update the `WindowGroup` body in `CatermSpikeApp.swift`:

```swift
WindowGroup("Caterm Spike") {
    Group {
        if let bridge = state.bridge {
            TerminalView(bridge: bridge) { cols, rows in
                state.ssh?.sendWindowChange(cols: cols, rows: rows)
            }
        } else if let err = state.error {
            Text("Bridge init failed: \(err)").padding()
        } else {
            Text("Initializing...").padding()
        }
    }
    .frame(minWidth: 800, minHeight: 500)
    .task { state.start() }
}
```

Also expose `ssh` on `AppState` (currently private) — change `private var ssh: SSHSpike?` to `var ssh: SSHSpike?`.

- [ ] **Step 8.3: Run and verify**

```bash
CATERM_SPIKE_HOST=your-host CATERM_SPIKE_USER=you CATERM_SPIKE_PASSWORD=secret \
    swift run --package-path apps/macos CatermSpike
```

In the spawned terminal:

1. Type `stty size` and press Return → note the dimensions, e.g., `24 80`
2. Drag the window corner to make it bigger
3. Type `stty size` again → expected: dimensions changed to reflect new window size

If `stty size` doesn't change: NIOSSH may not have sent the WindowChangeRequest, OR libghostty's resize call isn't firing. Add a `print` inside `propagateResize` and `sendWindowChange` to find which side is silent.

- [ ] **Step 8.4: Commit**

```bash
cd /Users/zingerbee/Documents/Caterm
git add apps/macos/Sources/
git commit -m "spike(phase-0): window resize propagates to libghostty + PTY (S6)"
```

**Append to progress file**: `S6 通过：拖拽窗口 → stty size 反映新尺寸`.

---

## Task 9: Spike Verdict & Decision Gate

**Goal:** Document the outcome of all 6 acceptance criteria and decide whether to proceed to Phase 1, fall back, or delay.

**Files:**
- Modify: `docs/superpowers/plans/2026-04-27-swift-migration-progress.md`
- Create (if needed): `docs/superpowers/specs/2026-XX-XX-spike-findings.md`

- [ ] **Step 9.1: Run the full S1-S6 checklist one more time**

Cold-start the app from a fresh shell. Confirm each criterion passes:

- [ ] **S1** Build succeeds: `cd apps/macos && swift build` → `Build complete!`
- [ ] **S2** Hardcoded byte rendering verified earlier; no regression after later changes
- [ ] **S3** SSH connects; stdout bytes appear (originally in console; now in surface)
- [ ] **S4** Remote shell prompt visible in surface within ~2s of app launch
- [ ] **S5** `echo $$` typed in surface produces a numeric PID in surface
- [ ] **S6** Resize window → `stty size` in shell shows updated dims

- [ ] **Step 9.2: Update progress file with verdict**

Append to `docs/superpowers/plans/2026-04-27-swift-migration-progress.md`:

If all 6 pass:

```
| YYYY-MM-DD | Phase 0 spike COMPLETE — S1-S6 全部通过；技术路径锁定。准备进入 Phase 1 v1 实施 |
```

Also bump the **当前阶段** section at the top:

```markdown
## 当前阶段

**Phase 1 — v1 implementation (pending plan)**

Spike 已通过 (Phase 0 done)。下一步：调用 `superpowers:writing-plans` 写 Phase 1 实施计划。
```

If any fail, instead append:

```
| YYYY-MM-DD | Phase 0 spike BLOCKED — Sx 失败：<原因>；触发决策（spec §5.2）：<决策> |
```

And open a new spec `docs/superpowers/specs/YYYY-MM-DD-spike-findings.md` with: which step failed, what was tried, what alternatives are now on the table (SwiftTerm, libssh2, delay, etc.).

- [ ] **Step 9.3: Capture libghostty / NIOSSH API deviations for Phase 1**

Even on success, the spike likely uncovered places where the spec's API placeholders don't match the real shape. Append to the progress file (or a new findings doc) a short list, e.g.:

```
- libghostty: `ghostty_surface_text` is actually `ghostty_surface_key` with mode flags
- libghostty: surface needs `cell_size` config in init (not in current GhosttyBridge)
- NIOSSH: half-closure must be set BEFORE the shell request, not after
- ghostty.h field <foo> renamed to <bar> as of vN
```

This list is the input to Phase 1's Task 1.0 ("clean restart"). Without it, Phase 1 will rediscover the same lessons.

- [ ] **Step 9.4: Commit verdict**

```bash
cd /Users/zingerbee/Documents/Caterm
git add docs/superpowers/plans/2026-04-27-swift-migration-progress.md
# also any spike-findings.md if you created one
git commit -m "spike(phase-0): record S1-S6 verdict and API deviation notes"
```

---

## Spike Done

If S1-S6 all passed, the spike has done its job. The code in `apps/macos/` is **throwaway** — Phase 1 Step 1.0 explicitly deletes it. The valuable artifacts that survive are:

1. **The pinned `Vendor/ghostty` submodule and `Scripts/build-libghostty.sh`** — preserve these into Phase 1
2. **The progress file's API deviation notes** — input to Phase 1 design adjustments
3. **The `.gitignore` and `.spike.local.json.example`** — pattern reused for Phase 1's local dev configs
4. **The actual Phase 0 commit history** — keep as a reference; squash if desired but don't lose the lessons

Per spec §5.3 nothing else carries over. Resist the urge to "save the good parts" — Phase 1 starts clean for a reason.

---

## Self-Review Checklist (for the engineer running this plan)

Before declaring Phase 0 complete:

- [ ] Every step's "Expected" output was actually observed (not assumed)
- [ ] No credentials in any committed file (`git log -p apps/macos/ | grep -i password` returns nothing)
- [ ] `git check-ignore apps/macos/.spike.local.json` passes
- [ ] All commits use `spike(phase-0):` prefix
- [ ] Progress file has 6 entries (S1-S6) with dates
- [ ] Verdict is recorded; if blocked, fallback decision is documented in a new spec
- [ ] You have NOT started writing Phase 1 code in this branch / worktree
