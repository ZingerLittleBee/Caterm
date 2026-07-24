# Changelog

All notable changes to the Caterm macOS and iOS apps are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### iOS

- Complete the executable cross-device continuity path for Hosts, encrypted
  credential material, reusable credential identities, snippets, compatible
  settings, and durable offline state.
- Route launch, foreground, pull-to-refresh, silent push, account changes,
  and manual refresh through one serialized iCloud sync coordinator.
- Show actionable iCloud sync status and recovery controls while keeping
  cached hosts and snippets available through transient network failures.
- Replace the file-browser preview with real NIO SFTP browsing and mutations,
  Files upload/export, iPad drag and drop, durable transfer progress,
  cancellation, conflict handling, typed failures, and safe interruption when
  iOS suspends the app.
- Keep Known Hosts authorization device-local even when Host metadata and
  encrypted credentials synchronize.

### macOS

- Add native multi-Pane Workspaces with split/focus commands, responder-scoped
  routing, and independent session lifecycle.
- Prepare reusable Workspace templates that always create fresh SSH sessions.
  Shipping remains gated on signed restoration, accessibility, and load proof
  in #55.
- Add reviewed command broadcast with frozen recipients, per-Pane outcomes,
  and no disconnected-session replay.
- Add startup snippets and non-secret Host environment variables with explicit
  review, suppression, and reconnect policy, verified against signed macOS and
  iOS SSH fixtures.
- Add reusable credential identities for passwords, keys, and SSH
  certificates. Signed physical-device acceptance verifies Secure Enclave
  identity creation, restart restoration, and authentication to a disposable
  OpenSSH fixture without exporting private key material.
- Prepare a native dual-pane File Transfer window for local/remote and
  cross-Host copies through the Mac, plus external-editor upload-back with
  explicit review and conflict protection. Shipping remains gated on the
  signed process/sandbox acceptance in #59.

### Documentation corrections

- Correct the 1.1.0 mobile sync claim. Version 1.1.0 introduced the mobile
  terminal and local mobile stores, but its live composition did not execute
  CloudKit Host/settings sync or durable snippet continuity. The complete
  executable path described above lands in the next release represented by
  this Unreleased section; the historical 1.1.0 notes remain unchanged below.
- Document that Workspace templates restore declarations as fresh sessions,
  Known Hosts trust is device-local, and iOS background suspension can
  interrupt terminals, tunnels, and transfers.

## [1.1.0] - 2026-05-17

Adds an iOS companion app — a Termius-style SSH terminal that reuses
Caterm's host store, credential keychain, and iCloud sync — alongside
macOS stability fixes and sync hardening.

### iOS app (new)

- Runnable SwiftUI iOS app sharing the host store, keychain-backed
  credentials, and iCloud host/settings sync with the Mac app.
- Real SSH over swift-nio-ssh: connection state machine, TOFU
  known-hosts store, derived auth plans, and a live terminal session.
- SwiftTerm-backed terminal screen with the full Termius-style key bar,
  terminal resize grid math, tabs, and a native keyboard toggle.
- Host management: tap-to-connect, swipe/long-press edit, delete
  confirmation, user-settable host icon, and a wired Settings screen.
- Terminal UX: hidden app tab bar and nav bar on the terminal, toolbar
  keyboard toggle, legible connection-failure UI, and a working
  Reconnect.
- Built via SwiftPM (not Xcode SPM integration); simulator-only SSH
  credential fallback plus a real-SSH simulator e2e driver.

### SSH & hosts

- Host-icon catalog with OS-availability filtering, user-settable per
  host, synced across devices via iCloud.
- SSH key sync: explicit-key sync, `~/.ssh` scan, and opt-in default
  upload.
- Port-forward UI rewritten in plain language with fixed proportions.
- Removed the non-functional Agent auth method from the host form.
- `⌘T` opens a new tab; shortcuts reveal on `⌘`-hold.

### Fixes

- Prevent app-termination deadlock in ControlMaster teardown.
- Sidebar table lookup resilient to row-count lag.
- Cache `RemoteFileSystem` per host instead of per render.
- Observe iCloud sign-in state in Sync settings; tie terminal connect
  probe to view lifecycle.
- Stop silent credential loss and persist a corrupt-blob bound.
- Key File fields no longer clipped in the host form.
- Connect overlay dismisses on the first remote OSC, not a 3s timer.

### Distribution

- Strip `keychain-access-groups` so AMFI doesn't SIGKILL askpass.
- Notarization supports direct credentials; dev provisioning profile
  auto-discovered from `sign/`.

## [1.0.0] - 2026-05-16

First public release. Native SwiftUI macOS SSH terminal manager built on
libghostty, with iCloud-backed sync and no self-hosted server dependency.

### Terminal

- Ghostty-powered terminal surfaces with tabbed sessions and a collapsible
  host-list sidebar (`⌘B` to toggle).
- Bundled `xterm-ghostty` terminfo with opt-in remote install per host.
- Full terminal settings UI (font, cursor, colors, behavior) backed by a
  managed Ghostty config snapshot with diagnostic surfacing.
- Theme catalog extracted from Ghostty at build time with a searchable
  picker, favorites grid, and per-host theme overrides.

### SSH

- Host CRUD with optional labels (falls back to `user@host`).
- Host chaining via `ProxyJump`, including a Via-host picker with chain
  preview, cycle detection, and per-session `ssh_config` generation.
- Port forwarding (local/remote/dynamic) configurable per host, emitted as
  `ssh_config` directives with skipped-forward banners.
- ControlMaster connection multiplexing with deterministic teardown.
- Chain-aware `caterm-askpass` for credential prompts across hops.
- Connection progress, failure, and reconnect overlays.

### SFTP

- File transfer drawer with a transfer queue.
- Persisted remote-path bookmarks per host.

### iCloud Sync (serverless)

- Host sync via CloudKit private database with incremental change tokens,
  compound CAS, and a 60-minute force-full safety net.
- End-to-end encrypted credential sync: AES-256-GCM blobs sealed under a
  master key in the synchronizable iCloud Keychain; ciphertext-only to Apple.
- Settings sync via `NSUbiquitousKeyValueStore` with revision-based
  last-writer-wins, quarantine on corrupt/incompatible blobs, and
  initial-sync grace handling.
- Silent-push acceleration via CloudKit subscriptions (best-effort; the
  load-bearing triggers are per-launch incremental + 60-min force-full +
  iCloud-account-change observers).
- Destructive credential-delete flow with tombstone propagation.
- Snippet store and sync.

### Distribution

- Production signing pipeline (`make dist`): release build, Distribution
  codesign with two-pass entitlement re-seal, provisioning-profile embed,
  and three-way entitlement verification.
- Optional inline notarization + stapling via `notarytool` / `stapler`.
- DMG packaging (`make dmg`, UDZO + `/Applications` symlink).
- App icon and bundle xattr-strip guards for clean codesigning.

### Known limitations

- Two-Mac live verification against the CloudKit **Production** container
  (`Manual/pre-ship-two-mac-smoke.md` §1/§2/§3) has not yet been executed.
- Requires macOS 14.0 or later.

[1.1.0]: https://github.com/ZingerLittleBee/Caterm/releases/tag/v1.1.0
[1.0.0]: https://github.com/ZingerLittleBee/Caterm/releases/tag/v1.0.0
