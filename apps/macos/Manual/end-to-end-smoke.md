# End-to-end askpass smoke

Run after every Task 1.3+ change to catch codesign / Keychain regressions.

## Prerequisites

- Apple Development cert installed in login keychain.
- `CATERM_DEV_IDENTITY` exported, e.g. `Apple Development: Bee Zinger (4GH398M5WH)`.
- The actual TeamIdentifier embedded in the cert is the OU field of the
  certificate subject. On this machine the cert CN is
  `Apple Development: Bee Zinger (4GH398M5WH)` but the OU (TeamIdentifier) is
  `9VM4RM39R3`. The dev-codesign.sh script extracts the real value from the
  cert and substitutes it for `$(TeamIdentifierPrefix)` in the entitlement
  files before signing, so the access group resolves to
  `9VM4RM39R3.caterm.shared`.
- Local OpenSSH server in Docker (used in Task 1.4+):
  ```
  docker run -d --name=caterm-smoke \
      -p 2222:2222 \
      -e PASSWORD_ACCESS=true \
      -e USER_NAME=spike \
      -e USER_PASSWORD=spikepass \
      lscr.io/linuxserver/openssh-server:latest
  ```

## Procedure

1. `cd apps/macos && swift build && ./Scripts/dev-codesign.sh`
2. Verify both binaries have the same TeamIdentifier:
   `codesign -dvv .build/debug/caterm{,-askpass} 2>&1 | grep TeamIdentifier`
3. Smoke-test the login-keychain read path (works without provisioning
   profile — see "Access group caveat" below):
   ```
   TEST_HOST_ID=00000000-0000-0000-0000-000000000001
   security add-generic-password -U \
       -s com.caterm.host -a "$TEST_HOST_ID.password" -w hunter2
   CATERM_HOST_ID="$TEST_HOST_ID" CATERM_ASKPASS_KIND=password \
       .build/debug/caterm-askpass
   security delete-generic-password \
       -s com.caterm.host -a "$TEST_HOST_ID.password"
   ```
   Expected: `hunter2` on stdout, exit 0, no dialog (after the first
   approval per session — login keychain ACL prompts once per session per
   process identity).
4. Full SSH path validation comes in Task 1.4+ once SessionStore wires it.

## Access group caveat (read this before debugging keychain issues)

The plan's Step 10 expected the signed askpass to query a team-prefixed
access group (`9VM4RM39R3.caterm.shared`) without macOS popping a dialog.
On Apple Silicon macOS, `keychain-access-groups` is a *restricted*
entitlement — AMFI requires either:

- An embedded development provisioning profile that whitelists the access
  group, OR
- A Developer ID + Notarization signature (production path).

Without one of these, the kernel kills the process at exec time with
SIGKILL (exit 137). amfid logs report:

> `Restricted entitlements not validated, bailing out. Error: ... "No matching profile found"`

For the v1 dev workflow we therefore use the **login keychain without
access group** path: both `caterm` and `caterm-askpass` run as the same
user and read items from the user's login keychain by `service+account`.
macOS' login-keychain ACL still allows access without a provisioning
profile, and the codesigned identity ensures the secret is bound to the
caterm processes (the user is prompted once per session to approve
access).

When we ship a real .app bundle in a later task, we will:

1. Embed a Mac development provisioning profile (or use Developer ID
   Application + Notarization).
2. Switch `KeychainStore` callers to set `accessGroup =
   "<TeamID>.caterm.shared"` so the GUI app and the askpass helper can
   both read the same access group without per-process ACL prompts.

The `KeychainStore` API already supports both modes — pass `nil` for
login-keychain (current dev mode), pass the access-group string for
production mode.

## Terminal Interaction (v1.5)

Run after every change to the AppKit ↔ libghostty mouse / scroll / cursor
plumbing. Requires the OpenSSH-in-Docker setup from the Prerequisites
section.

1. **Drag-select** — Connect to the smoke host, run `ls -la`, then click and
   drag across some output. Selection highlight should follow the drag and
   stop when you release.
2. **Mouse-reporting (`htop`)** — `htop` on the remote, click the column
   headers (CPU%, MEM%) at the top. The list should re-sort, proving libghostty
   is forwarding mouse-button events under DECSET 1000/1002/1006.
3. **Vim cursor positioning + Shift override** — `vim some-file`, click
   somewhere in the buffer; the cursor should jump there. Then hold Shift
   while drag-selecting — that should bypass mouse-reporting and produce a
   normal terminal selection.
4. **Cursor flips to I-beam on hover** — Move the mouse into the terminal
   view; the cursor should change from the default arrow to an I-beam, and
   back to arrow when the pointer leaves the view. This proves the
   `GHOSTTY_ACTION_MOUSE_SHAPE` action is round-tripping through the
   action callback into `NSCursor`.
5. **Copy / Paste end-to-end (⌘C / ⌘V)** — Drag-select some terminal
   output, ⌘C, then run `pbpaste` outside Caterm — the selected text
   should appear. Then `printf hello | pbcopy` outside Caterm, focus the
   terminal, ⌘V — `hello` should reach the SSH prompt. Edit menu items
   should grey-out correctly: Copy disabled when there is no selection,
   Paste disabled when the system clipboard is empty.
6. **Right-click context menu** — Right-click in the terminal; a small
   menu with "Copy" and "Paste" should appear. Their enable state should
   match the Edit menu (Copy iff selection, Paste iff clipboard string).
7. **OSC 52 write (auto-allow)** — On the remote SSH host, run:
   `printf '\e]52;c;%s\a' "$(printf hello | base64)"`. Locally, `pbpaste`
   should now return `hello` — no confirm sheet appears (writes are
   auto-confirmed per spec §5.4 policy B).
8. **OSC 52 read (confirm sheet)** — On the remote, run
   `printf '\e]52;c;?\a'`. A modal sheet should appear with **Deny** as
   the default button (Enter or Esc denies). "Allow Once" should deliver
   the current clipboard contents; "Deny" should reply with no data.
9. **Drag-drop file path** — Drag a file from Finder into the terminal.
   The PTY should receive a shell-quoted version of the absolute path
   (single-quoted; spaces / quotes preserved). Multi-file drags should
   produce space-separated quoted paths.
10. **`read_clipboard_cb` thread tripwire** — In a debug build, exercise
    all the above without ever tripping the `Thread.isMainThread` assert
    in `GhosttyApp.readClipboardCallback`. If it fires, halt and revisit
    spec §6 (6-OQ-2 fallback) — libghostty is calling read off-main and
    the `MainActor.assumeIsolated` block becomes a deadlock risk.
11. **IME composition (Pinyin / Kotoeri / dead-keys)** — Covers spec §8 manual
    checklist item 8 (IME composition with preedit + candidate anchor).
    1. **Printable ASCII regression** — In a fresh prompt, run
       `cat | xxd` and type `abc123`. The hex output must show
       `61 62 63 31 32 33` exactly once (no duplicate bytes from the
       ghostty-key-first + `interpretKeyEvents` path).
    2. **US-International dead-key** — System Settings → Keyboard →
       Input Sources, add "U.S. International - PC" and switch to it.
       Press `⌥e` then `e`; the terminal should receive `é` (a single
       composed character).
    3. **Pinyin (Simplified Chinese)** — Add "Pinyin - Simplified" input
       source and switch to it. Type `nihao`. While composing, an
       underline preedit `nǐhǎo` should render inline at the terminal
       cursor (preedit goes through `setPreedit`). Press space; the
       commit `你好` reaches the PTY (via `sendText`) and the preedit
       clears.
    4. **Candidate panel anchor** — During the Pinyin composition above,
       the candidate window should appear directly under the terminal
       cursor (not in a screen corner). This proves
       `firstRect(forCharacterRange:)` is converting libghostty's
       view-local cursor rect to screen coordinates correctly.
    5. **F-keys in `vim`** — Switch back to ABC input, run `vim`. F1
       opens help; F2/F3/etc. should produce their expected escape
       sequences (vim's `:nmap <F5>` etc. should fire). This proves the
       Ctrl-chord short-circuit doesn't accidentally swallow the
       function keys.
12. **Ctrl-chord no-duplicate (5.5-OQ-2 mitigation)** — Covers spec §8
    manual checklist item 7 (Ctrl-chord pass-through, no AppKit
    interpretation duplicates). At a `cat | xxd` prompt:
    - `⌃A` → output contains `01` exactly once (not `01 01`, which
      would indicate AppKit's "moveToBeginningOfLine:" doCommand path
      re-emitted on top of libghostty's raw key path).
    - `⌃E` → `05` once.
    - `⌃K` → `0b` once.
    - `⌃Y` → `19` once.
    If any chord produces duplicates, revisit the `isCtrlChord`
    short-circuit in `GhosttySurfaceNSView.keyDown`.
13. **URL hover + ⌘-click open (whitelisted scheme)** — Covers spec §8 manual
    checklist item 9 (URL hover cursor + open). On the SSH host run
    `printf 'https://example.com\n'`. Move the pointer over the URL — the
    text should pick up an underline (libghostty's link decoration). Hold
    ⌘ while still hovering: the cursor flips from I-beam to pointing hand.
    ⌘-click the URL — the system default browser opens
    `https://example.com`. The cursor should return to I-beam when ⌘ is
    released or the pointer leaves the link.
14. **URL hover prompt (rejected scheme)** — Covers spec §8 manual
    checklist item 10 (scheme whitelist confirm sheet). On the SSH host
    run `printf 'file:///etc/passwd\n'`. ⌘-click the rendered URL — a
    modal "Open this URL?" sheet should appear with **Cancel** as the
    default button (Enter or Esc cancels). "Open" should hand the URL to
    `NSWorkspace`, "Cancel" should suppress it. Repeat with
    `javascript:alert(1)` and `x-apple-data-detectors:0` — same prompt.
15. **Scrollback keybind round-trip (managed config)** — Exercises the
    Caterm-managed keybind snapshot loaded between libghostty defaults
    and the user config (spec §8 manual checklist item 12).
    1. In a terminal: `yes | head -200` to fill the scrollback. Then:
       - `⌘↑` scrolls up one line, `⌘↓` scrolls down one line
         (`scroll_page_lines:-1` / `+1`).
       - `⌘⇞` (PageUp) scrolls up one page, `⌘⇟` (PageDown) one page
         (`scroll_page_fractional:-1` / `+1`).
       - `⌘Home` jumps to the top of scrollback (`scroll_to_top`).
       - `⌘End` jumps back to the bottom (`scroll_to_bottom`).
       - `⌘K` clears the visible screen (`clear_screen`).
    2. **Alt-screen passthrough** — Run `vim` (or `htop`); the
       alt-screen takes over and there is no scrollback. The mouse wheel
       should translate to ↑/↓ keystrokes (vim moves the cursor); the
       seven keybinds above are scrollback-only and need not navigate
       inside the alt-screen.
    3. **User override wins** — Add a line to
       `~/Library/Application Support/Caterm/config`, e.g.
       `keybind = super+k=paste_from_clipboard`, restart Caterm, and
       confirm `⌘K` now pastes instead of clearing the screen. This
       proves the load order: defaults → managed → user, and that the
       user file is the last write so its keybinds win.
    4. Verify `~/Library/Application Support/Caterm/caterm-managed.config`
       exists after launch and matches `ConfigStore.managedConfigContent`
       byte-for-byte. The file is rewritten only when content drifts
       (idempotency guard in `writeManagedConfig`), so repeated launches
       should not bump its mtime.

If any of these regress, the most common culprits are:

- Tracking area not refreshed (resize doesn't re-call `updateTrackingAreas`)
- Action callback firing off-main (the `Thread.isMainThread` assert in
  `GhosttyApp.actionCallback` should catch this in debug)
- Scroll deltas not multiplied by `cellSize` for imprecise wheels — symptom
  is one mouse-wheel notch barely moves the buffer

## Failure modes

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Exit 137 from caterm-askpass | binary signed with `keychain-access-groups` but no provisioning profile | use login-keychain path (do not set `CATERM_ACCESS_GROUP`) until provisioning profile is wired |
| Keychain dialog popup | first-time access by a freshly resigned binary | click "Always Allow" once; subsequent runs are silent |
| `spawn askpass: Permission denied` | binary not executable | `chmod +x .build/debug/caterm-askpass` |
| `Permission denied (password,publickey)` | secret not in keychain | run KeychainStore set via Task 1.7 UI; or re-add via signed test harness |
| Exit code 3 with osStatus -25243 | access group entitlement mismatch | re-check Resources/CatermAskpass.entitlements |
| Exit code 3 with osStatus -25291 | login keychain locked | unlock via Keychain Access |
