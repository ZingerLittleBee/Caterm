# Changelog

All notable changes to the Caterm macOS app are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[1.0.0]: https://github.com/ZingerLittleBee/Caterm/releases/tag/v1.0.0
