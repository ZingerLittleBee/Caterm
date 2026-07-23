# Caterm

**English** | [简体中文](README.zh-CN.md)

A native SSH terminal manager for macOS, iPhone, and iPad with iCloud sync
and no self-hosted server.

[![Latest release](https://img.shields.io/github/v/release/ZingerLittleBee/Caterm)](https://github.com/ZingerLittleBee/Caterm/releases/latest)

Caterm uses [libghostty](https://github.com/ghostty-org/ghostty) on macOS and
a native NIO SSH terminal on iOS. Hosts, reusable credential identities,
compatible settings, and snippets sync across your devices over iCloud.
Credential secrets are end-to-end encrypted and never leave your devices in
the clear. There is no Caterm account to create and no backend to run.

## Download

[Download the latest release](https://github.com/ZingerLittleBee/Caterm/releases/latest).
The app is Developer ID signed, notarized, and stapled. Grab
`Caterm-<version>.dmg`, open it, and drag Caterm to Applications.

Requires **macOS 14.0 or later**. The iOS companion targets **iOS and
iPadOS 17.0 or later** and is currently built from source.

The feature inventory below describes the current `main`/Unreleased source.
The latest packaged release may not include every listed capability; see
[CHANGELOG.md](CHANGELOG.md) for the release boundary.

Sync needs the device to be signed into iCloud — there is no separate
account. Signed out or temporarily offline, Caterm keeps cached Hosts and
snippets available locally and pauses remote sync work. Routine sync is
automatic, with explicit status and manual recovery when attention is needed.

## Screenshots

![Caterm terminal with tabs and host sidebar](docs/images/hero.png)

| Host chaining | SFTP drawer | Themes |
|---|---|---|
| ![Host chaining](docs/images/host-chaining.png) | ![SFTP drawer](docs/images/sftp-drawer.png) | ![Theme picker](docs/images/theme-picker.png) |

| Terminal settings | iCloud sync |
|---|---|
| ![Terminal settings](docs/images/settings.png) | ![iCloud sync settings](docs/images/sync.png) |

## Features

### Terminal

- Ghostty-powered macOS terminal surfaces with native window tabs and a
  collapsible Host sidebar (`⌘B` to toggle).
- Native macOS Workspaces with horizontal and vertical Panes, directional
  focus, Focus/Split presentation, and independent reconnect and close
  behavior.
- Reviewed command broadcast takes a frozen snapshot of eligible Panes in the
  focused Workspace, shows the exact recipients before delivery, reports one
  result per Pane, and never buffers commands for disconnected or reconnecting
  sessions.
- Bundled `xterm-ghostty` terminfo with opt-in remote install per host.
- Full terminal settings UI (font, cursor, colors, behavior) backed by a
  managed Ghostty config snapshot with diagnostic surfacing.
- Theme catalog extracted from Ghostty with a searchable picker, favorites
  grid, and per-host theme overrides.
- Native iPhone and iPad terminal sessions with a mobile key strip, software
  and hardware keyboard support, synchronized snippets, reconnect, and
  device-local host-key verification.

### SSH

- Host CRUD with optional labels (falls back to `user@host`).
- Nested Host groups and tags with search and bulk organization.
- Host chaining via `ProxyJump`, with a Via-host picker, chain preview,
  cycle detection, and per-session `ssh_config` generation.
- Port forwarding (local/remote/dynamic) per host.
- ControlMaster connection multiplexing with deterministic teardown.
- Chain-aware askpass for credential prompts across hops.
- Reusable credential identities for passwords, private keys, and SSH
  certificates. Portable secrets remain encrypted.

### SFTP and files

- A macOS file drawer that follows the active Workspace Pane, with a shared
  transfer queue and persisted remote-path bookmarks.
- Real iPhone and iPad SFTP over NIO: browse, create folders, rename, delete,
  upload from Files, download to an explicit export/share destination, drag
  completed files on iPad, and inspect transfer progress and typed failures.
- iOS backgrounding cancels unfinished transfers safely. Caterm does not claim
  that SSH or SFTP continues indefinitely after the app is suspended.

### iCloud sync (serverless)

- Host sync via the CloudKit private database with incremental change
  tokens and a force-full safety net.
- End-to-end encrypted credential sync: AES-256-GCM blobs sealed under a
  master key in the synchronizable iCloud Keychain — ciphertext-only to
  Apple.
- Settings sync via `NSUbiquitousKeyValueStore` with revision-based
  last-writer-wins and quarantine on corrupt/incompatible blobs.
- Snippet store and sync.
- The live iOS composition uses durable Host, snippet, settings, credential,
  and transfer stores. Launch, foreground, pull-to-refresh, silent push,
  account change, and manual refresh enter one serialized sync coordinator.
- Cached Hosts and snippets remain available while iCloud is signed out,
  temporarily unavailable, or offline.

## Deliberate boundaries

- Known Hosts trust is device-local. Each Mac, iPhone, and iPad verifies a
  server independently; an iCloud-synced Host does not carry another device's
  trust decision.
- Workspace templates describe fresh sessions, not resumable live remote
  processes. Use `tmux`, `screen`, or another server-side multiplexer when the
  remote process must survive a client disconnect.
- iOS may suspend Caterm shortly after it enters the background. Cached data
  stays available, but terminals, tunnels, and transfers are not advertised
  as always-on background services.
- Caterm is SSH-first. Telnet, Serial, Mosh, RDP, VNC, SCP, cloud-provider
  inventory, AI command generation, raw-keystroke broadcast, synchronized
  terminal output, and team collaboration are not part of the current
  individual-user product.
- Workspace template restoration, signed Pane accessibility/load acceptance,
  Secure Enclave identity authentication, cross-platform startup automation,
  and the desktop dual-pane/external-editor SFTP workspace exist in source but
  remain verification-gated. A Workspace template's defined contract creates
  fresh SSH sessions; it never preserves a live PTY, socket, remote process,
  working directory, or terminal output. These capabilities are not
  advertised as shipped until
  [#55](https://github.com/ZingerLittleBee/Caterm/issues/55),
  [#58](https://github.com/ZingerLittleBee/Caterm/issues/58),
  [#57](https://github.com/ZingerLittleBee/Caterm/issues/57), and
  [#59](https://github.com/ZingerLittleBee/Caterm/issues/59) close.
- See the [Termius parity matrix](docs/termius-parity.md) for the evidence and
  disposition of every verified comparison capability.

## Security

Caterm syncs SSH credentials, so the encryption model is deliberate:

- **Credentials are end-to-end encrypted.** Each credential field is sealed
  with **AES-256-GCM** (authenticated with associated data binding it to its
  host, field, and revision) before it ever leaves the device.
- **The master key lives only in your iCloud Keychain.** It is a 256-bit
  symmetric key stored as a *synchronizable* Keychain item, so it
  propagates between authorized devices through Apple's end-to-end-encrypted
  iCloud Keychain — Apple cannot read it. Device-bound private material is
  not portable and does not synchronize.
- **Different data, different paths.** Sealed credential blobs ride on
  CloudKit `Host` records; the master key rides iCloud Keychain. Apple sees
  only ciphertext on the CloudKit side and never holds the key to it.
- **Settings** sync via `NSUbiquitousKeyValueStore` and are not sensitive;
  a corrupt or schema-incompatible blob is quarantined rather than applied.
- **Known Hosts trust stays local to each device.** Caterm syncs connection
  metadata, not host-key authorization decisions.
- **CloudKit never receives the credential key.** A lost device may already
  hold locally accessible Keychain material, so Caterm relies on the device
  passcode, FileVault, Keychain access control, and Apple's device-management
  or remote-erase controls. Removing a device from Apple ID prevents future
  account access; it is not a substitute for remote erase.

There is no Caterm server and no Caterm account — nothing to breach on our
side because there is no "our side".

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
make ghostty-kit

make run-app          # build + codesign + wrap in Caterm.app + launch
```

`make run-app` is the default dev loop — the bare binary crashes on launch
because the app registers for APS push, which requires a bundle identity.

## Development

```bash
make test             # swift test
make build            # swift build (debug)
make doctor           # toolchain / signing diagnostics
make help             # list all targets
```

Codesigning for local development resolves an identity from
`CATERM_DEV_IDENTITY`, `.dev-identity`, or the login keychain.
See [`docs/macos-dev-signing.md`](docs/macos-dev-signing.md) for the signing
pitfalls and the full rationale.

### Debugging

```bash
make run-app          # build + codesign + wrap in Caterm.app + launch (foreground)
make run-bg           # same, but background; stdout/stderr -> /tmp/caterm.log
make kill             # kill the running dev process

tail -f /tmp/caterm.log               # follow logs from `make run-bg`
log stream --predicate 'subsystem == "com.caterm.app"' --level debug  # os_log
```

Always use `make run-app` / `make run-bg`, not the bare binary (`make run`):
the app calls `NSApp.registerForRemoteNotifications()` on launch, which
requires a bundle identity — the bare binary crashes there.

To step through with a debugger, attach LLDB to the debug build:

```bash
make build
lldb .build/debug/caterm           # (lldb) run
# or attach to an already-running instance:
lldb -p "$(pgrep -nf .build/debug/caterm)"
```

Runtime logging goes through `os_log` under subsystem `com.caterm.app`
(filter by category in Console.app — e.g. `cloudkit-sync`,
`snippet-sync`, `signing-diag`).

## Release

### One-time setup (maintainers)

Building a distributable, notarized release requires your own Apple
Developer account. All identity and credentials live outside git in the
gitignored `sign/` directory — nothing personal is committed.

1. A **Developer ID Application** certificate for your team in the login
   keychain.
2. A **Distribution provisioning profile** (Developer ID type) for your
   App ID, configured with `aps-environment=production` and
   `icloud-container-environment=Production`. Save it as
   `sign/Caterm_Developer_ID.provisionprofile` — `release.sh`
   auto-resolves it there.
3. A **notarytool keychain profile** named `caterm` (the app-specific
   password is prompted securely; never commit it):

   ```bash
   xcrun notarytool store-credentials caterm \
       --apple-id <your-apple-id> --team-id <your-team-id>
   ```

4. The **CloudKit schema deployed to Production** once via the CloudKit
   Console (Schema → Deploy to Production) for your iCloud container.

`make doctor` prints the resolved signing diagnostics if anything is off.

### Per release

```bash
# 1. Add a new version section (with date) at the top of the CHANGELOG.
$EDITOR CHANGELOG.md

# 2. Build + Developer ID sign + notarize + staple + dmg.
make release
#    make release ARGS=--skip-notary   signed-only (smoke on your own Macs)
#    make release ARGS=--skip-dmg      .app only, no disk image

# 3. Tag + GitHub release + upload the .dmg and zipped .app.
make publish
#    make publish ARGS=--dry-run       print every action, mutate nothing
#    (--draft is not supported: Sparkle's feed reads releases/latest, which skips drafts)
```

`make release` ([`Scripts/release.sh`](Scripts/release.sh))
auto-resolves the Developer ID identity, provisioning profile, and notary
profile, then runs build → distribution codesign (two-pass entitlement
re-seal + askpass entitlement isolation) → bundle assembly → notarize →
staple → dmg → Gatekeeper assessment.

`make publish` ([`Scripts/publish-release.sh`](Scripts/publish-release.sh))
is Gatekeeper-gated — it refuses to publish a build that is not notarized
and stapled — pushes an annotated `v<version>` tag, and creates the
GitHub release with notes pulled from the matching
[`CHANGELOG.md`](CHANGELOG.md) section. The CHANGELOG
version drives the tag, so it must point at the commit you intend to
release (clean tree, pushed to `origin/main`).

### Auto-update (Sparkle)

`make publish` also generates and uploads `appcast.xml` so that installed
copies of Caterm self-update automatically. Users can also trigger a check
manually via the **Caterm app menu → Check for Updates…** (next to About Caterm). The release version and build
number are read from the top `## [X.Y.Z]` entry in `CHANGELOG.md` — no
manual version env var is needed.

`--draft` releases are not compatible with the Sparkle feed: GitHub's
`/releases/latest` redirect skips drafts, so the appcast would not be
served. Use `--dry-run` for a rehearsal instead.

The first Sparkle-enabled release must be distributed manually (older
installed builds have no updater). Auto-update works from that version
onward.

## Architecture

A Swift Package Manager project (`Package.swift`) split into
focused modules — terminal engine, SSH command builder, session store,
CloudKit/credential/settings sync clients, SFTP, and the SwiftUI app
target. There is no backend service: all sync flows through the user's
private CloudKit database and iCloud Keychain.

## Acknowledgements

Caterm's terminal is powered by [Ghostty](https://github.com/ghostty-org/ghostty)
(libghostty), vendored as a submodule and built into `GhosttyKit.xcframework`.
Ghostty is MIT-licensed; thanks to Mitchell Hashimoto and the Ghostty
contributors.

## License

[MIT](LICENSE) © ZingerLittleBee. The bundled libghostty is MIT-licensed
and remains under its own terms.
