# Phase 0 Spike Findings (2026-04-27)

**Status:** Spike PASS — S1-S6 all observed. **Architecture pivot required for Phase 1.**

**Branch:** `spike/phase-0`
**Submodule pin:** `apps/macos/Vendor/ghostty` @ `bc90a5128` (post-v1.3.1, includes fat-static-archive fix)

---

## S1-S6 verdict

| Crit | What it proved | How it was verified |
|------|-----------------|----------------------|
| **S1** Build | swift-tools 5.10, macOS 14, libghostty xcframework binaryTarget links | `swift build` clean; binary 17M arm64; `otool -L` shows Carbon, Metal, MetalKit, AppKit, libc++ all resolved |
| **S2** Render | libghostty's surface paints into NSView via Metal | Window opens, `$SHELL` prompt visible (`zsh@host%` with cell grid + cursor) |
| **S3** SSH connect | libghostty spawns `ssh user@127.0.0.1 -p 2222`, ssh accepts host key (TOFU) and authenticates | `Warning: Permanently added '[127.0.0.1]:2222' (ED25519) to the list of known hosts.` rendered in surface |
| **S4** Remote stdout in surface | Bytes from the ssh subprocess flow through libghostty's PTY into the cell grid | `Welcome to OpenSSH Server` banner + `a8ac88a43268:~$` prompt rendered |
| **S5** Keyboard → SSH stdin | NSEvent keyDown → `ghostty_surface_key` → libghostty PTY write → ssh stdin → remote shell | Sent `echo PID=$$` + Return programmatically; surface showed `PID=238` |
| **S6** Resize → PTY | `ghostty_surface_set_size` propagates through libghostty's PTY to the remote `stty` | Window resized 800x500 → 1400x900; `stty size` went from `14 76` → `41 145` |

Screenshots captured during run: `/tmp/spike-screen5.png` (S2), `/tmp/spike-ssh.png` (S3+S4), `/tmp/spike-key3.png` (S5), `/tmp/spike-resize3.png` (S6).

---

## The architecture pivot

### What we discovered

libghostty 1.3.x's public C API (`ghostty.h`) **has no entry point for injecting external bytes into a surface**. The surface is configured with at most `command`, `working_directory`, `env_vars`, `initial_input`, `wait_after_command`, `nsview`/`scale_factor` — and that's it. Internally, `src/termio/backend.zig` declares only `pub const Kind = enum { exec };`. There is exactly one terminal IO backend and it `posix_exec`s a process under a PTY that libghostty owns end-to-end.

### What the spec assumed

`docs/superpowers/specs/2026-04-27-tauri-to-swift-migration-design.md` §3 sketches:

```
swift-nio-ssh ─(NIO event loop)─► AsyncThrowingStream<Data> ─(MainActor)─► GhosttyBridge.feed(data)
                                  ▲                                          ▲
                                  │                                          └── doesn't exist
                                  └── BoundedByteChannel backpressure
```

The `feed(data)` arrow is the missing API. Everything upstream (NIO handler, EmbeddedChannel test harness in §6.3, BoundedByteChannel in §3.2, allowRemoteHalfClosure plumbing in §4.2) only matters if libghostty would accept the bytes — which it won't.

### What the spike did instead

Set `ghostty_surface_config_s.command = "/usr/bin/ssh -p PORT user@host"` (with optional `sshpass -e` for the spike-only password path). libghostty spawns ssh, owns the PTY, owns the host key dialog (StrictHostKeyChecking=accept-new), owns the auth, owns the resize. Our Swift layer is a thin window + key event forwarder.

This works. It's also how Ghostty.app itself does SSH — there's no special handling, just a `command` setting.

---

## Implications for Phase 1 v1

The following spec sections need rewriting before the Phase 1 plan is drafted:

- **§3.1 SSH transport:** Drop swift-nio-ssh from v1. Surface uses `/usr/bin/ssh`. The "transport" module shrinks to a `command` builder.
- **§3.2 BoundedByteChannel / backpressure:** Not applicable when libghostty owns the PTY. Remove.
- **§4.1 KnownHostStore + TOFU dialog:** ssh's own `~/.ssh/known_hosts` + `StrictHostKeyChecking=accept-new` (or `=ask` with an askpass). The Swift TOFU dialog UX moves to v1.1+ if ever; no `KnownHostStore` actor in v1.
- **§4.2 Half-closure / autoRead toggling:** N/A — it was an NIO concern.
- **§6.3 EmbeddedChannel integration test:** N/A. Replace with a Docker-OpenSSH-server smoke test (we used `lscr.io/linuxserver/openssh-server` successfully in the spike — keep that in CI/manual test docs).
- **§7.1 Credential storage:** v1 leans on the user's existing ssh-agent + `~/.ssh/config`. Keychain lands when we want a "Caterm-managed credential" UX, but that requires an askpass binary that talks to Keychain; this is plausibly v1.1 work, not v1.
- **§7.1.3 local id ↔ server id mapping:** Still relevant — host metadata sync stays the same in v1.1.
- **D2 (SSH library choice):** Decision now reads "system `/usr/bin/ssh`, not a Swift SSH library." swift-nio-ssh / Citadel / libssh2 evaluation moves to a v2 SFTP context (where we DO need Swift-side SSH control because libghostty doesn't speak SFTP).

The following sections survive intact:

- §2 priority ordering (A>B>D>C)
- §5.1 spike scope (already done)
- §7.1.3 double-ID host mapping
- §8 distribution channels
- All feature scope cuts (no v1 sync, no v1 SFTP, no FS browser)

### v2 SFTP path (parking lot)

When SFTP becomes the goal (v2), `command="ssh ..."` won't fly because libghostty isn't an SFTP client. v2 will likely need swift-nio-ssh after all — but in a separate "transfer" subsystem that's not coupled to libghostty's surface. The spec §3.1 swift-nio-ssh research is therefore not wasted; it just shifts to a later milestone.

---

## libghostty / Ghostty build issues encountered

Worth recording so Phase 1 doesn't rediscover them:

1. **v1.3.1 ships a broken macOS slice.** The macOS arm64/x86_64 slice in `GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a` only exports 4 symbols (the SIMD helpers); `libghostty_zcu.o` (with all 89 embedding-API exports) is missing from the libtool-merged archive. Fix landed post-1.3.1 as commits `94e638d08` and `bc90a5128` ("build: produce fat static archive on all platforms" + "build: fat static archive and ubsan fix for external linkers"). **Pin a commit ≥ `bc90a5128`** until v1.3.2 ships.

2. **Zig version is exact.** Ghostty's `build.zig.zon` declares `.minimum_zig_version = "0.15.2"`; we install via `brew install zig@0.15` (keg-only) and point the build script at `/opt/homebrew/opt/zig@0.15/bin/zig`. Don't rely on whatever `zig` is on PATH.

3. **Xcode 26 Metal Toolchain is a separate download.** First build fails with `cannot execute tool 'metal' due to missing Metal Toolchain`. Run `xcodebuild -downloadComponent MetalToolchain` (needs sudo via osascript GUI dialog — no `--non-interactive` mode); 687.9MB cryptex install. Once installed, `xcrun metal --version` still fails on the wrapper but the actual build at `/var/run/com.apple.security.cryptexd/mnt/.../bin/metal` works.

4. **Zig build of `-Demit-xcframework=true` chains into a full-app `xcodebuild` step that depends on Sparkle / dock-tile and fails for an embedder.** The xcframework itself is produced before that step. Our build script tolerates a non-zero exit code and only errors if the xcframework directory is missing.

5. **SwiftPM rejects static libs without `lib` prefix.** Ghostty's macOS slice ships as `ghostty-internal.a`. Build script renames in-place to `libghostty-internal.a` and patches the xcframework `Info.plist` `BinaryPath`/`LibraryPath` accordingly.

6. **System framework links aren't auto-pulled by binaryTarget.** Package.swift has to declare `linkedFramework("Carbon", "Metal", "MetalKit", "CoreText", "CoreGraphics", "CoreFoundation", "AppKit", "UniformTypeIdentifiers")` and `linkedLibrary("c++", "z", "bz2", "iconv")`. Missing any of these surfaces as the same `Undefined symbols for architecture arm64` error.

7. **CLI binary needs explicit activation.** SwiftUI app launched via `.build/.../CatermSpike` (no `.app` bundle) is treated as a background process; the window stays hidden. Adding `NSApplication.shared.setActivationPolicy(.regular)` + `activate(ignoringOtherApps:true)` in `init()` fixes it. Phase 1 ships an `.app` bundle (via `swift-bundler`) so this won't carry over.

---

## Throwaway code, surviving artifacts

Per spec §5.3 the `apps/macos/Sources/CatermSpike/*.swift` is throwaway. What survives into Phase 1:

- `apps/macos/Vendor/ghostty` submodule pin (`bc90a5128`) and `apps/macos/Scripts/build-libghostty.sh`
- `apps/macos/Frameworks/.gitignore` pattern for the produced xcframework
- `apps/macos/.spike.local.json` gitignore + `.example` shape (carry forward to dev configs)
- This findings doc + the progress log entries
- The `libghostty PTY 所有权` memory entry (so future sessions don't re-discover this)

Phase 1 starts with a fresh `apps/macos/Sources/Caterm/` tree.

---

## Decision gate

**Recommendation:** Proceed to Phase 1 design rewrite (the spec sections listed above). The spike has answered its central question — libghostty + macOS Swift can deliver an SSH terminal — but the v1 transport layer is fundamentally simpler than the spec assumed. The plan should reflect that smaller scope.

Open question for the user before rewriting Phase 1:

- **Auth UX in v1:** OK to lean on the user's existing ssh-agent + `~/.ssh/config` (no Caterm-managed credentials) and let v1.1 add a Keychain-backed askpass? Or is "passwords stored in the app" a v1 must-have?

If the answer is "v1 must store passwords": we need a Keychain askpass binary in v1. Doable but adds a chunk of work. Otherwise v1 is much closer to "host list + libghostty surface" with the auth machinery deferred.
