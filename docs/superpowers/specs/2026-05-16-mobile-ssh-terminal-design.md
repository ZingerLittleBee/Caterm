# Caterm Mobile SSH Terminal Design

## Objective

Give the iOS/iPadOS app a **real, usable SSH terminal** with a
mobile-first interaction model inspired by Termius. The user's directive:
mobile UX is paramount, implementation cost is not a concern. This
supersedes the phase-1 terminal placeholder.

## Hard Constraints (from code exploration)

- iOS has no `Process`, no PTY for spawning arbitrary binaries, and no
  `/usr/bin/ssh`. The macOS app's terminal is libghostty, whose surface
  *owns its own PTY and spawns a local command*; its wrapper is AppKit
  only (`GhosttySurfaceNSView`, `GHOSTTY_PLATFORM_MACOS`). **libghostty
  is not viable on iOS** and `TerminalEngine` stays macOS-only and
  untouched.
- Real SSH on iOS therefore requires an **in-process SSH client** and a
  **byte-stream terminal emulator/renderer**. The package currently has
  zero third-party dependencies; two are introduced here. Per the user's
  explicit decision ("you make all decisions, cost no object"), this is
  approved.

## Decisions

- **SSH transport:** `swift-nio-ssh` (Apple, pure-Swift, Sendable-aware,
  fits the repo's strict-concurrency standards). One shell channel per
  session with an interactive PTY request; window-change on resize.
- **Terminal emulation + rendering:** `SwiftTerm` (mature pure-Swift
  xterm/VT emulator with a UIKit `TerminalView`). SSH channel bytes feed
  `TerminalView.feed`; `TerminalViewDelegate.send` writes back to the SSH
  channel.
- **Isolation:** new SPM library target `CatermMobileTerminal`
  (dependencies: `NIOSSH`, `SwiftTerm`, `SSHCommandBuilder`,
  `KeychainStore`). `CatermMobile` depends on it. macOS targets are
  unaffected; the new deps never enter the `Caterm` executable graph.
- **Credentials:** reuse `SSHHost` + the keychain account convention from
  `MobileCredentialPlan` (`<hostId>.password` / `.keyPassphrase`,
  service `com.caterm.host`). Missing material is prompted in-flow.
- **Host keys:** Trust-On-First-Use. A `MobileKnownHostsStore`
  (JSON under Application Support + fingerprint) records accepted keys;
  first contact or a mismatch raises an explicit trust prompt.

## Architecture

Units, each independently testable:

1. **SSHAuthPlan** (pure) — given an `SSHHost` + available keychain
   material, produce the ordered auth attempts (publicKey, password,
   keyboard-interactive) and what secret each needs. Surfaces "needs
   password/passphrase" as an explicit state.
2. **MobileKnownHostsStore** — load/save accepted host-key fingerprints;
   `evaluate(host, presentedKey) -> .trusted | .unknown | .mismatch`.
3. **TerminalKeyBar** (pure) — model for the Termius-style accessory bar:
   key set, sticky-Ctrl state, and `bytes(for:)` mapping a key (with
   modifiers) to the exact terminal byte sequence (e.g. Ctrl-C → 0x03,
   ↑ → ESC [ A, Esc → 0x1b, Tab → 0x09, Home/End/PgUp/PgDn, Fn row).
4. **TerminalResize** (pure) — pixel size + font metrics → (cols, rows)
   for the PTY window-change request; clamps and ignores no-op churn.
5. **SSHTerminalSession** (`actor`) — owns the NIOSSH connection +
   channel lifecycle: connect, authenticate (driven by SSHAuthPlan),
   host-key callback (driven by MobileKnownHostsStore), open shell with
   PTY, stream stdout/stderr, accept input, send window-change, and a
   typed state machine (`connecting → hostKeyPrompt? → authPrompt? →
   connected → disconnected(reason)`), never swallowing errors.
6. **SwiftTermBridge** (`@MainActor`) — wraps `SwiftTerm.TerminalView`
   in a `UIViewRepresentable`; pipes session bytes → `feed`, delegate
   `send` → session, `sizeChanged` → TerminalResize → session.
7. **MobileTerminalSessionView** (SwiftUI) — the full-screen Termius-style
   session screen: terminal fills safe area; accessory `TerminalKeyBar`
   above the keyboard; session toolbar (disconnect, paste, font size,
   keyboard toggle); connection lifecycle overlays (connecting spinner,
   host-key trust sheet, credential prompt, error/disconnect state with
   reconnect). Gestures: tap focus, two-finger scrollback, pinch font
   size, long-press select/copy, paste.

Wiring: the existing mobile "Connect" route
(`MobileHostActions.connectRoute`) stops returning the placeholder for a
ready host and instead navigates to `MobileTerminalSessionView(host:)`,
which builds an `SSHTerminalSession` from the host + keychain. The
phase-1 `MobileTerminalPlaceholderView` is removed from the connect path
(kept only as the explicit state when a host genuinely cannot connect).

## Data Flow

```
SSHHost + Keychain ──> SSHAuthPlan ──┐
MobileKnownHostsStore ───────────────┤
                                     v
              SSHTerminalSession (actor, NIOSSH)
                 stdout/stderr bytes │ ▲ input bytes / window-change
                                     v │
                 SwiftTermBridge (TerminalView.feed / delegate.send)
                                     v │
                 MobileTerminalSessionView (keybar, gestures, toolbar)
```

## Error Handling & UX States

- Every failure is a typed `SSHTerminalSession` state rendered in the UI
  (unreachable, auth failed, host-key mismatch, channel closed, timeout)
  — never console-only. Disconnect offers reconnect.
- Host-key unknown/mismatch blocks I/O until the user explicitly trusts.
- Missing password/passphrase pauses auth with an inline secure prompt;
  on success it is offered to the keychain via the existing credential
  writer.
- Rotation / keyboard show-hide recomputes size and sends window-change
  so the remote `$COLUMNS/$LINES` track the visible area.

## Testing & Verification

Not complete until there is real evidence:

- **Unit (TDD):** SSHAuthPlan ordering/needs; MobileKnownHostsStore
  trust/mismatch; TerminalKeyBar byte sequences (Ctrl/arrows/Esc/Tab/Fn);
  TerminalResize math and no-op suppression.
- **Integration — real SSH:** stand up a real OpenSSH server reachable
  from the simulator (local `sshd` on a high port with a throwaway
  config + test keypair, or the existing Docker E2E pattern). An
  end-to-end test/script: build+install the iOS app, connect to the real
  server, drive input via idb (`echo CATERM_OK_$RANDOM`), screenshot,
  and assert the terminal rendered the expected output. macOS suite
  (`make test`) stays green with zero regressions.
- iOS simulator build/run/tap is confirmed working on this machine; idb
  usable via the documented event-loop shim + manual companion.

## Non-Goals

- No changes to macOS `TerminalEngine`/libghostty or the macOS app shell.
- No SFTP/file-transfer on iOS in this effort (separate platform-safe
  transport work).
- No multi-tab/split sessions in this pass — one host, one full-screen
  session. Multiple sessions can follow once the single session is solid.
- No CloudKit sync changes.

## References

- libghostty surface is PTY/command-based and AppKit-bound
  (`Sources/TerminalEngine/GhosttySurface.swift`) — rationale for not
  reusing it on iOS.
- Existing real-SSH harness pattern:
  `Tests/SessionStoreTests/EndToEndSSHTests.swift` (Docker, gated by
  `CATERM_E2E_DOCKER=1`).
- Mobile credential keying: `Sources/CatermMobile/MobileCredentialFlow.swift`.
- iOS sim/idb verification notes: project memory
  `caterm_ios_sim_verification.md`.
