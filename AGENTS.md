# Caterm — Agent Guide

Caterm is a **native macOS SSH terminal manager**: a SwiftUI app built on
[libghostty](https://github.com/ghostty-org/ghostty), with iCloud sync
(CloudKit + iCloud Keychain) and no self-hosted server. Standard Swift
Package Manager layout — `Package.swift` at the repo root.

## Commands

```bash
make ghostty-kit   # init Ghostty submodule + build Frameworks/GhosttyKit.xcframework
make run-app       # build + codesign + wrap in Caterm.app + launch (default dev loop)
make test          # swift test
make build         # swift build (debug)
make doctor        # toolchain / signing diagnostics
make release       # build + sign + notarize + staple + dmg
make publish       # tag + GitHub release + upload artifacts
make help          # list all targets
```

`make run-app` (not the bare binary) is the default dev loop — the app
registers for APS push on launch, which requires a bundle identity.

`GhosttyKit.xcframework` is generated from the `Vendor/ghostty` submodule
via `Scripts/build-libghostty.sh`, which needs Homebrew `zig@0.15`
(expected at `/opt/homebrew/opt/zig@0.15/bin/zig`).

## Layout

- `Package.swift` — SwiftPM manifest; modular targets.
- `Sources/` — `Caterm` (SwiftUI app) plus focused libraries:
  TerminalEngine, SSHCommandBuilder, SessionStore, CloudKitSyncClient,
  CredentialSync, SettingsSyncStore, SnippetStore, FileTransferStore, etc.
- `Tests/` — XCTest targets mirroring the source modules.
- `Scripts/` — build/sign/release tooling.
- `Resources/` — entitlements, app icon, terminfo.
- `Manual/` — manual smoke checklists.
- `Vendor/ghostty` — Ghostty submodule (libghostty source).
- `sign/` — gitignored signing credentials (never commit).

## Signing & release

Local dev codesign resolves an identity from `CATERM_DEV_IDENTITY`,
`.dev-identity`, or the login keychain. Distribution signing, notarization,
provisioning profile, and the CloudKit Production requirement are
documented in `README.md` (Release) and `docs/macos-dev-signing.md`. The
release version is driven by the top entry of `CHANGELOG.md`.

## Code standards

Write accessible, type-safe, maintainable Swift with explicit intent.

- Prefer value types and `struct`s; use `actor` / `@MainActor` for
  concurrency boundaries; never block the main actor.
- Make illegal states unrepresentable (enums with associated values over
  boolean flags); exhaustive `switch` over `default:` where practical.
- Use `guard` for early exits; avoid force-unwraps (`!`) and `try!`
  outside tests.
- Throw typed `Error`s with context; never swallow errors silently.
- Keep sync invariants intact — CloudKit / credential / settings sync has
  load-bearing state machines; read the relevant module and its tests
  before changing behavior, and add or extend tests for any change.
- Run `make test` before committing; keep the suite green.

## Agent skills

### Issue tracker

Issues and PRDs are tracked in GitHub Issues via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles map directly to labels with the same names. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository with `CONTEXT.md` and `docs/adr/` at the root. See `docs/agents/domain.md`.
