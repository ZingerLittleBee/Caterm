# Snippet sync — manual verification

**Required environment:** iCloud Production for two-Mac scenarios (silent push is throttled in Development).

## Single-Mac scenarios

### S1. Persistence across relaunch
1. Create snippet "test-1" with content "echo hi".
2. Quit Caterm (⌘Q).
3. Relaunch. Expected: "test-1" appears in palette.

### S2. Edit + delete cycle
1. Create snippet "edit-me".
2. Edit name → "edited".
3. Delete it.
4. Quit + relaunch. Expected: not present, snippets.json clean.

## Two-Mac scenarios (Production env required)

### S3. Cross-Mac propagation
1. On Mac A, create snippet "shared-1".
2. Wait ≤ 30s (silent push) or ≤ 60min (force-full timer).
3. On Mac B, open palette. Expected: "shared-1" appears.

### S4. Concurrent edit (LWW)
1. Both Macs online. Edit the same snippet within ~5s of each other.
2. Trigger sync on both.
3. Expected: later push wins. Earlier push's Mac re-fetches and reconciles.

### S5. Tombstone propagation (incl. offline)
1. Mac A: airplane mode. Delete snippet "to-delete".
2. Quit Caterm. Relaunch. Restore network.
3. Expected: outbox-driven retry pushes tombstone; Mac B sees disappear.

### S6. iCloud account switch
1. Mac A: log out of iCloud.
2. Expected: snippets.json + outbox cleared (verify via Console.app).
3. Log in as a different iCloud user.
4. Expected: that user's snippets fetched; previous user's snippets do not bleed.

## Run-mode acceptance (Task 0 spike outcome: B′)

The spike chose **path (B′)** — `sendText(content)` followed by a synthesized
Return via `ghostty_surface_key`. Code-evidence is conclusive on bash 5 and
zsh 5.9; fish 3 needs live confirmation since fish uses its own line editor
(Commandline) instead of GNU readline.

Execute the §5.4 spec matrix on a real SSH host with all three shells
available:

| Test | Shells | Expected |
|---|---|---|
| Single-line `echo hello` (Run) | bash 5, zsh 5.9, fish 3 | Output `hello`; prompt advances. |
| Multi-line `for i in 1 2 3; do echo $i; done` (Run) | bash 5, zsh 5.9 | Loop body executes; prints `1`, `2`, `3`; prompt advances. |
| Multi-line `for i in 1 2 3; echo $i; end` (Run) | fish 3 | Same expected output; if fish executes line-by-line instead, file a follow-up to fall back to per-line dispatch in fish. |
| `$(date)` substitution (Run) | bash 5 | Substitution happens in shell, not pre-expanded by terminal. |
| Snippet with leading whitespace (Run) | bash 5 with `HISTCONTROL=ignorespace` | Whitespace preserved; `history \| tail -1` does NOT include the snippet. |
| CJK IME preedit active (Run, Paste) | bash 5 | Preedit cleared by `setPreedit("")` defensive call; no character corruption. |
| Multi-line `for` loop (Paste) | bash 5 | Body sits at the prompt across multiple visual lines; pressing Return manually executes; nothing auto-executes. |

## Pass / fail tracking

| Scenario | Date | Mac pair | Result | Notes |
|---|---|---|---|---|
| S1 | | A solo | | |
| S2 | | A solo | | |
| S3 | | A↔B | | |
| S4 | | A↔B | | |
| S5 | | A↔B | | |
| S6 | | A↔B | | |
| Run mode bash | | A solo | | |
| Run mode zsh | | A solo | | |
| Run mode fish | | A solo | | highest-uncertainty per spike |

## CloudKit Dashboard schema

Before two-Mac runs, deploy the `Snippet` record type per spec §3.13 to the
`iCloud.com.caterm.app` container. In Development, CloudKit auto-creates
fields on first push; verify all field types match the spec after the first
successful `pushSnippet`. Promote to Production before silent push works
reliably across devices.

## Entry points to smoke (single-Mac)

- ⌘⇧P → palette opens (palette focuses search field; type to filter).
- ⌘⇧S → editor opens in create mode.
- View → Manage Snippets… → manager sheet opens (search + master/detail).
- Per-tab toolbar button (text-cursor icon) → palette opens for that tab's
  active surface.
