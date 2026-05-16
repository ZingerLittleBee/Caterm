# Caterm

A native macOS SSH terminal manager with iCloud sync and no self-hosted server.

[![Latest release](https://img.shields.io/github/v/release/ZingerLittleBee/Caterm)](https://github.com/ZingerLittleBee/Caterm/releases/latest)

Caterm is a SwiftUI app built on [libghostty](https://github.com/ghostty-org/ghostty)
for the terminal engine. Hosts, credentials, settings, and snippets sync
across your Macs over iCloud — credentials are end-to-end encrypted and never
leave your devices in the clear. There is no account to create and no backend
to run.

## Download

[Download the latest release](https://github.com/ZingerLittleBee/Caterm/releases/latest).
The app is Developer ID signed, notarized, and stapled. Grab
`Caterm-<version>.dmg`, open it, and drag Caterm to Applications.

Requires **macOS 14.0 or later**.

## Features

### Terminal

- Ghostty-powered terminal surfaces with tabbed sessions and a collapsible
  host-list sidebar (`⌘B` to toggle).
- Bundled `xterm-ghostty` terminfo with opt-in remote install per host.
- Full terminal settings UI (font, cursor, colors, behavior) backed by a
  managed Ghostty config snapshot with diagnostic surfacing.
- Theme catalog extracted from Ghostty with a searchable picker, favorites
  grid, and per-host theme overrides.

### SSH

- Host CRUD with optional labels (falls back to `user@host`).
- Host chaining via `ProxyJump`, with a Via-host picker, chain preview,
  cycle detection, and per-session `ssh_config` generation.
- Port forwarding (local/remote/dynamic) per host.
- ControlMaster connection multiplexing with deterministic teardown.
- Chain-aware askpass for credential prompts across hops.

### SFTP

- File transfer drawer with a transfer queue.
- Persisted remote-path bookmarks per host.

### iCloud sync (serverless)

- Host sync via the CloudKit private database with incremental change
  tokens and a force-full safety net.
- End-to-end encrypted credential sync: AES-256-GCM blobs sealed under a
  master key in the synchronizable iCloud Keychain — ciphertext-only to
  Apple.
- Settings sync via `NSUbiquitousKeyValueStore` with revision-based
  last-writer-wins and quarantine on corrupt/incompatible blobs.
- Snippet store and sync.

## Build from source

### Prerequisites

- macOS 14.0+ with the Xcode command-line tools (Swift 5.10+).
- Homebrew [`zig@0.15`](https://formulae.brew.sh/formula/zig@0.15) — required
  to build libghostty. Expected at `/opt/homebrew/opt/zig@0.15/bin/zig`.

### Steps

```bash
git clone https://github.com/ZingerLittleBee/Caterm.git
cd Caterm

# Init the Ghostty submodule and build Frameworks/GhosttyKit.xcframework
make macos-ghostty-kit

cd apps/macos
make run-app          # build + codesign + wrap in Caterm.app + launch
```

`make run-app` is the default dev loop — the bare binary crashes on launch
because the app registers for APS push, which requires a bundle identity.

## Development

```bash
cd apps/macos
make test             # swift test
make build            # swift build (debug)
make doctor           # toolchain / signing diagnostics
make help             # list all targets
```

Codesigning for local development resolves an identity from
`CATERM_DEV_IDENTITY`, `apps/macos/.dev-identity`, or the login keychain.
See [`docs/macos-dev-signing.md`](docs/macos-dev-signing.md) for the signing
pitfalls and the full rationale.

## Release

```bash
cd apps/macos
make release          # build + sign + notarize + staple + dmg
make publish          # tag + GitHub release + upload artifacts
```

`make publish` is Gatekeeper-gated (it refuses to publish a build that is
not notarized and stapled) and pulls release notes from the matching
section of [`apps/macos/CHANGELOG.md`](apps/macos/CHANGELOG.md). The
CHANGELOG version drives the tag.

## Architecture

A Swift Package Manager project (`apps/macos/Package.swift`) split into
focused modules — terminal engine, SSH command builder, session store,
CloudKit/credential/settings sync clients, SFTP, and the SwiftUI app
target. There is no backend service: all sync flows through the user's
private CloudKit database and iCloud Keychain.
