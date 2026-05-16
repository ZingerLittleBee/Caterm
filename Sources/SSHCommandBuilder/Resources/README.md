# `xterm-ghostty.terminfo` — bundled terminfo source

This file is a **manual snapshot** of Ghostty's `xterm-ghostty` terminfo entry,
shipped as a SwiftPM resource so Caterm's SSH command builder can stream it
into a remote `tic -x -` over the wire (see v1.6 design,
`docs/superpowers/specs/2026-04-29-task-v1.6-terminfo-auto-install-design.md`).

## Pinning

- **Ghostty version this snapshot tracks:** `1.3.1`
- **Upstream tag:** `https://github.com/ghostty-org/ghostty/releases/tag/v1.3.1`
- **Source-of-truth (Zig):**
  - `https://github.com/ghostty-org/ghostty/blob/v1.3.1/src/terminfo/ghostty.zig`
  - `https://github.com/ghostty-org/ghostty/blob/v1.3.1/src/terminfo/Source.zig`

Caterm does **not** add Zig to its build pipeline. Instead, the snapshot is
reverse-derived from a verified Ghostty install (its terminfo was produced by
Ghostty's own Zig toolchain — we just textualize it).

## Regen workflow

Run this when bumping `Frameworks/GhosttyKit.xcframework`:

```bash
# 1. Make sure the installed Ghostty.app version matches the libghostty bump.
defaults read /Applications/Ghostty.app/Contents/Info.plist CFBundleShortVersionString

# 2. Regenerate the snapshot.
infocmp -x xterm-ghostty > apps/macos/Sources/SSHCommandBuilder/Resources/xterm-ghostty.terminfo

# 3. Update the Ghostty version line above in this README.

# 4. Validate by running the Docker E2E test on a real GNU/Linux remote.
CATERM_E2E_DOCKER=1 swift test --filter TerminfoIntegrationTests
```

If step 4 fails, the snapshot is incompatible with GNU `tic`; revert and
investigate (it would mean BSD `infocmp -x` produced output GNU `tic` can't
parse — a parser-drift bug worth filing upstream).
