# Run-mode injection spike — outcome

**Date:** 2026-05-06
**Spec section:** §5.3 / §5.4 of `2026-05-06-macos-snippets-design.md`

## Mechanism chosen

**(B′) `sendText(content)` + synthesized `Return` via `ghostty_surface_key`.**

The body is delivered through libghostty's existing paste path (which wraps it
in `\e[200~ ... \e[201~` when bracketed-paste mode is active — typical for
bash 5 / zsh 5.9 / fish 3 at a normal prompt). Immediately after, a
synthesized Return keystruct is sent through `ghostty_surface_key`, which goes
through the keyboard protocol path and emits a real `\r` to the PTY. Bash /
zsh / fish readline ends bracketed paste on `\e[201~`, leaves the buffered
content at the prompt, then receives `\r` as a normal Return and submits the
buffered line(s) for execution.

The synthesized Return is built as a hand-constructed `ghostty_input_key_s` —
no NSEvent forgery — calling `ghostty_surface_key` directly. This avoids the
brittleness of `NSEvent.keyEvent(with:...)` synthesis and reuses the exact
same C entry point the existing `GhosttySurface.sendKey(_:composing:)`
wrapper drives at `apps/macos/Sources/TerminalEngine/GhosttySurface.swift:217`.

## Confidence

**high** for the code-evidence portion (mechanism correctness, paste-path
behavior, key-path behavior, IME safety). **medium** on the cross-shell
acceptance matrix (§5.4) — the bracketed-paste finalizer behavior is a
de-facto readline contract, but fish 3 uses its own line editor (Commandline)
rather than GNU readline. A short live smoke against bash, zsh, and fish on
one connected SSH host is required before Task 19 ships. See "Live validation
required" below.

## Evidence

### What `sendText` does

`GhosttySurface.sendText(_:)` is a thin wrapper at
`apps/macos/Sources/TerminalEngine/GhosttySurface+IME.swift:17-22`:

```swift
func sendText(_ s: String) {
    guard !s.isEmpty else { return }
    s.withCString { ptr in
        ghostty_surface_text(raw, ptr, UInt(strlen(ptr)))
    }
}
```

`ghostty_surface_text` is the only text-injection C export in libghostty
(verified by exhaustive grep of the xcframework header — see "Candidate (A)"
below). Its in-source documentation comment is explicit
(`apps/macos/Vendor/ghostty/src/apprt/embedded.zig:1814-1823`):

```
/// Send raw text to the terminal. This is treated like a paste
/// so this isn't useful for sending escape sequences. For that,
/// individual key input should be used.
export fn ghostty_surface_text(...) void {
    surface.textCallback(ptr[0..len]);
}
```

`textCallback` (the embedded apprt wrapper) calls
`core_surface.textCallback(text)` at
`apps/macos/Vendor/ghostty/src/apprt/embedded.zig:900-905`. The core surface's
`textCallback` is at `apps/macos/Vendor/ghostty/src/Surface.zig:3253-3264`:

```
/// Sends text as-is to the terminal without triggering any keyboard
/// protocol. This will treat the input text as if it was pasted
/// from the clipboard so the same logic will be applied. Namely,
/// if bracketed mode is on this will do a bracketed paste. Otherwise,
/// this will filter newlines to '\r'.
pub fn textCallback(self: *Surface, text: []const u8) !void {
    ...
    try self.completeClipboardPaste(text, true);
}
```

So `sendText` is unconditionally routed through `completeClipboardPaste`.

### Bracketed paste mechanism in this libghostty

`completeClipboardPaste` at
`apps/macos/Vendor/ghostty/src/Surface.zig:6041-6118` does two things:

1. Reads `Options.bracketed` from
   `input.paste.Options.fromTerminal(&self.io.terminal)` —
   `apps/macos/Vendor/ghostty/src/input/paste.zig:9-13`:

   ```zig
   pub fn fromTerminal(t: *const Terminal) Options {
       return .{ .bracketed = t.modes.get(.bracketed_paste) };
   }
   ```

   So bracketed paste is gated on the **terminal mode 2004** state, which the
   shell toggles. Bash 5, zsh 5.9, and the typical readline init enable mode
   2004 by default at an interactive prompt.

2. Calls `input.paste.encode(data, opts)` —
   `apps/macos/Vendor/ghostty/src/input/paste.zig:34-111`. With
   `bracketed = true` it returns `["\x1b[200~", data, "\x1b[201~"]`
   (lines 95-99). With `bracketed = false` it leaves the body unwrapped
   but rewrites `\n` → `\r` in-place (lines 101-110).

The wrap is added inside libghostty (Zig core), **not** in the Swift wrapper.
There is no apprt-side bypass.

The encoder also strips a hard-coded set of "unsafe" bytes (NUL, BS, ESC, DEL,
Ctrl-C/Ctrl-Z/etc.) by replacing them with spaces — same set xterm uses, see
`apps/macos/Vendor/ghostty/src/input/paste.zig:42-91`. This applies in both
modes. It is harmless for our snippet content (we already exclude ESC etc. as
not useful in saved snippets) but worth noting.

### Candidate (A) — raw text API

**Result: no such API exists.**

Exhaustive grep of `apps/macos/Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h`
for every `ghostty_surface_*` C export and any text-shaped name
(`text|paste|write|inject|insert|input`) yields exactly three text-input
entry points (see lines 1124-1129, 1153 of the header):

| Symbol | Behavior |
|---|---|
| `ghostty_surface_key(surface, ghostty_input_key_s)` | Keyboard protocol path. Emits via KeyEncoder → PTY. Not paste-wrapped. |
| `ghostty_surface_text(surface, char*, len)` | Paste path. Always routes through `completeClipboardPaste`. |
| `ghostty_surface_preedit(surface, char*, len)` | IME marked text — does NOT write to PTY, only updates the inline preedit display. |
| `ghostty_surface_binding_action(surface, name, len)` | Triggers a named binding action. The only paste-related actions are `paste_from_clipboard` / `paste_from_selection` (`apps/macos/Vendor/ghostty/src/input/Binding.zig:353-356`), both of which go through the paste path. There is no `paste_unwrapped` / `execute` / `write_raw` action. |

There is no Zig-side raw-write export either. Confirmed by listing every
`export fn ghostty_*` in `apps/macos/Vendor/ghostty/src/apprt/embedded.zig`
(grep at line 1398 onwards). Candidate (A) is unavailable without patching
ghostty itself.

### Candidate (B) / (B′) — sendKey

`GhosttySurface.sendKey(_:composing:)` at
`apps/macos/Sources/TerminalEngine/GhosttySurface.swift:217-277` translates an
`NSEvent` into a `ghostty_input_key_s` and calls `ghostty_surface_key`.
Internally (`apps/macos/Vendor/ghostty/src/apprt/embedded.zig:1780-1791`) this
hits `surface.app.keyEvent(...)`, which routes through the KeyEncoder. This
path **does not** go through `completeClipboardPaste`, so it is unaffected by
bracketed paste mode. A real `\r` keystroke reaches the PTY directly and is
interpreted as Return by readline.

For Run mode we only need to synthesize one Return keystroke after the body
goes out as paste. The macOS native keycode for Return is 0x24 (36),
confirmed at `apps/macos/Vendor/ghostty/src/input/keycodes.zig:271`:

```
.{ 0x070028, 0x001c, 0x0024, 0x001c, 0x0024, "Enter" },
```

(field 4 is the macOS native code, mapped from `kVK_Return`).

The existing `sendKey` requires an NSEvent because it pulls
`event.characters(byApplyingModifiers: [])` to compute `unshifted_codepoint`
and `event.isARepeat` for the action. We do not need to forge an NSEvent —
`ghostty_input_key_s` is exposed directly to Swift (already used at
`GhosttySurface.swift:257`). For Return we know the values statically:
`keycode = 36`, `unshifted_codepoint = 0x0D`, `text = nil` (because
`\r` < 0x20 — the same rule the existing `sendKey` applies at
`GhosttySurface.swift:252`), `mods = 0`, `consumed_mods = 0`,
`composing = false`, `action = GHOSTTY_ACTION_PRESS`.

**IME interactions.** `sendText` is the same C entry that the IME-commit path
uses (`GhosttySurfaceNSView+TextInput.swift:46`). When the snippet palette is
the focused responder, the terminal view does not own keyboard focus, so it
holds no `markedString` and no preedit buffer; `sendText` from the palette
runs at a quiescent IME state. As a defensive measure the snippet helper also
calls `setPreedit("")` before dispatch (no-op when already clear). This
matches the IME contract documented in `GhosttySurface+IME.swift:24-34`.

The synthesized Return passes `composing: false`, mirroring how a real
post-IME-commit Return reaches libghostty.

### Why this mechanism

(A) is unavailable — there is simply no raw-text C export. (B) per-character
synthesis is reachable but has three real downsides we avoid: it has to forge
NSEvents (or bypass them anyway), it deals with non-ASCII codepoint mapping
across keyboard layouts, and it is O(n) main-thread work for large snippets.
(B′) is the smallest correct change: one paste-wrapped body + one synthesized
Return. Bracketed-paste end-marker `\e[201~` releases readline's paste
finalizer cleanly before the Return arrives, so multi-line `for ... do ... done`
content is submitted as a single readline edit buffer (executed as a single
compound command, exactly as if a human pressed Return after pasting).

## Implementation reference

For Task 19 (`GhosttySurface+SnippetInjection.swift`), the chosen mechanism
is implemented as:

```swift
import AppKit
import GhosttyKit

@MainActor
public extension GhosttySurface {
    /// Paste mode: deliver content through the paste path. Bracketed-paste
    /// wrapping (when the shell has mode 2004 enabled) keeps multi-line
    /// content sitting at the prompt for the user to inspect / press Return.
    func pasteSnippet(_ content: String) {
        guard !content.isEmpty else { return }
        // Defensive: clear any stale preedit before injecting. The palette
        // owns focus so this is normally already empty; idempotent.
        setPreedit("")
        sendText(content)
    }

    /// Run mode: deliver content via the paste path, then a synthesized
    /// Return keystroke via the keyboard-protocol path. The bracketed-paste
    /// end-marker (\e[201~) released by the body causes readline to finalize
    /// paste mode; the subsequent synthesized \r is delivered as a real
    /// Return and submits the buffered line(s) to the shell for execution.
    func executeSnippet(_ content: String) {
        guard !content.isEmpty else { return }
        setPreedit("")
        sendText(content)
        sendSynthesizedReturn()
    }

    /// Builds a ghostty_input_key_s for the Return key directly (no NSEvent
    /// synthesis) and calls ghostty_surface_key. Mirrors the field choices
    /// in `sendKey(_:composing:)` for a real Return event:
    ///   - keycode = 0x24 (kVK_Return — the macOS native code libghostty
    ///     looks up in its keycodes table; verified against
    ///     ghostty/src/input/keycodes.zig:271).
    ///   - unshifted_codepoint = 0x0D ('\r').
    ///   - text = nil because '\r' < 0x20 (matches the rule at
    ///     GhosttySurface.swift:252-253).
    ///   - mods / consumed_mods = 0; composing = false.
    private func sendSynthesizedReturn() {
        var k = ghostty_input_key_s()
        k.action = GHOSTTY_ACTION_PRESS
        k.mods = ghostty_input_mods_e(0)
        k.consumed_mods = ghostty_input_mods_e(0)
        k.keycode = 0x24
        k.unshifted_codepoint = 0x0D
        k.text = nil
        k.composing = false
        _ = ghostty_surface_key(raw, k)
    }
}
```

## Live validation required

Code evidence is conclusive on the mechanism but cannot prove the cross-shell
acceptance matrix (§5.4). Before Task 19 ships, run a manual smoke against an
SSH host that has all three shells available:

| Test | Shells | Expected |
|---|---|---|
| Single-line `echo hello` (Run) | bash 5, zsh 5.9, fish 3 | Output `hello`; prompt advances. |
| Multi-line `for i in 1 2 3; do echo $i; done` (Run) | bash 5, zsh 5.9, fish 3 (use `for i in 1 2 3; echo $i; end` for fish) | Loop body executes; prints `1`, `2`, `3`; prompt advances. |
| `$(date)` substitution (Run) | bash 5 (sufficient) | Substitution happens in shell, not pre-expanded by terminal. Output is a date string. |
| Snippet with leading whitespace (Run) | bash 5 with `HISTCONTROL=ignorespace` | Whitespace preserved; `history | tail -1` does NOT include the snippet. |
| Snippet sent while a CJK IME preedit exists in the terminal (Run, Paste) | bash 5 | Preedit cleared; no character corruption; snippet runs cleanly. (Sanity test for `setPreedit("")` defensive call. Should also work without it but we want to confirm.) |
| Multi-line `for` loop (Paste) | bash 5 | Body sits at the prompt across multiple visual lines; pressing Return manually executes; nothing auto-executes. |

The fish row is the highest-uncertainty case — fish does not use GNU readline
(it uses its own Commandline editor) but it does implement bracketed paste
mode 2004. If fish does not finalize bracketed paste on `\e[201~` followed by
a real Return, B′ degrades to "fish executes line-by-line" (because each `\n`
inside the wrapped body is sent as `\r` only when bracketed mode is OFF —
when ON, `\n` is preserved verbatim inside the wrap and fish's paste handler
is responsible for either inserting or executing). If observed, the
remediation is documented in the spec §5.3 (C): ship Paste-only for fish, or
extend ghostty with a public raw-input API. This is a v1 decision the human
makes after the smoke.

## If outcome was (C)

Not applicable.
