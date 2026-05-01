---
name: macos-gui-self-test
description: |
  End-to-end self-verification for macOS Caterm UI changes. Triggers when:
  user reports a visible bug in the Caterm SwiftUI app (sidebar truncation,
  SFTP file drawer layout, host row rendering, terminal pane sizing, etc.),
  user says "自己测试" / "你自己看" / "自主验证" / "verify it yourself", or
  when about to claim a UI fix is done.

  Use BEFORE committing any apps/macos/Sources/Caterm/Views/** change as
  proof the fix actually renders correctly — never assume a SwiftUI layout
  edit works just because it compiles. Drives Caterm via cliclick + osascript,
  captures with screencapture, and reads the PNG via the Read tool to inspect
  pixels directly.
---

# macOS GUI Self-Test (Caterm)

Drive a real running Caterm.app from the shell, capture screenshots, and inspect them via the Read tool. This is the only reliable way to verify a SwiftUI layout fix in this project — `swift build` succeeding means nothing visually.

## When this skill applies

- Any edit under `apps/macos/Sources/Caterm/Views/**` whose intent is visible behavior
- After a `make macos-*` rebuild when the user is about to test
- Any time the user has expressed frustration that previous "fixes" weren't actually verified

## Required tooling

```
cliclick        # brew install cliclick — mouse + key automation
screencapture   # built-in
osascript       # built-in — only used to read/set window frame and send keystrokes
sips            # built-in — read image dimensions
```

The Read tool inspects PNG content directly; this is what makes "looking at the running app" possible from a CLI session.

## The Loop

```
1. Edit code
2. make -C apps/macos kill
3. make -C apps/macos run-bg     # logs → /tmp/caterm.log, prints pid
4. open -a caterm                 # bring to front
5. osascript: get window frame
6. osascript: set position {0, 50} and size {1500, 700}
7. cliclick: drive the UI to the target state
8. screencapture -R + Read: verify pixels
9. If wrong, go to 1; if right, commit
```

Always step 6 BEFORE step 7. Caterm's window may be on a second display or partially off-screen; pinning it to (0, 50) at 1500×700 puts the entire window in the primary display's logical bounds (1920×1080).

## Window control snippets

```bash
# Get window frame
osascript -e 'tell application "System Events" to tell process "caterm" to {position, size} of front window'
# → 0, 50, 1500, 700  (logical px)

# Force frame
osascript <<'EOF'
tell application "System Events"
  tell process "caterm"
    set position of front window to {0, 50}
    set size of front window to {1500, 700}
  end tell
end tell
EOF

# Activate (must come before cliclick on a backgrounded app)
osascript -e 'tell application "caterm" to activate'

# List all windows (useful when there are multiple LandingView/MainWindow tabs)
osascript <<'EOF'
tell application "System Events"
  tell process "caterm"
    set out to ""
    repeat with w in (every window)
      set out to out & (name of w) & "|" & (item 1 of (position of w)) & "," & (item 2 of (position of w)) & "|" & (item 1 of (size of w)) & "x" & (item 2 of (size of w)) & linefeed
    end repeat
    return out
  end tell
end tell
EOF
```

## Driving the UI

```bash
# Single click
cliclick c:130,100

# Double click — but see "Pitfalls" below; SwiftUI .onTapGesture(count:2) is fussy
cliclick dc:130,100

# More reliable double-click for SwiftUI count:2 gestures
cliclick c:130,100 c:130,100

# Right-click (context menu)
cliclick rc:130,100

# Press Escape (dismiss menus)
cliclick kp:esc

# Keyboard shortcut via osascript (cliclick can't do modifiers + key well)
osascript -e 'tell application "System Events" to keystroke "f" using {command down, shift down}'

# Click a menu bar item
osascript <<'EOF'
tell application "System Events"
  tell process "caterm"
    click menu item "Zoom" of menu "Window" of menu bar 1
  end tell
end tell
EOF
```

Caterm-specific shortcuts (defined in `CatermApp.swift`):

| Shortcut | Action |
|---|---|
| ⌘N | New Window (LandingView) |
| ⌘T | New Host (opens add sheet) |
| ⌘⇧F | Toggle SFTP / file drawer |
| ⌘, | Settings |
| ⌘↑ | (in file drawer) up to parent folder |

## Capture + inspect

```bash
# Whole logical screen (primary display)
screencapture -x -R 0,0,1920,1080 /tmp/shot.png

# Just the Caterm window (combine with osascript-fetched frame)
screencapture -x -R 0,50,1500,700 /tmp/shot.png

# Verify image was written
ls -la /tmp/shot.png

# Get image dimensions (image is in physical pixels; -R was logical)
sips -g pixelWidth -g pixelHeight /tmp/shot.png
```

Then call the Read tool on `/tmp/shot.png`. The model sees the actual rendering.

## Coordinate gotchas (read this twice)

- **Two coordinate systems coexist.** `screencapture -R x,y,w,h` takes **logical** points. The PNG it writes is **physical** pixels — on a Retina display that's 2× larger in each dimension. So a 1500×700 capture writes a 3000×1400 PNG. When eyeballing positions in the captured PNG, divide by 2 to convert back to logical px before passing to `cliclick`.
- **Multi-display.** Two 4K displays in this setup. The primary's logical bounds are 0,0 → 1920,1080. Caterm can spawn at (790, 183) on a fresh launch — partially visible, partially clipped — until you `set position` it.
- **`cliclick` always uses logical px** (same as osascript position).

## Pitfalls observed in this project

1. **`cliclick dc:` doesn't always trigger `.onTapGesture(count: 2)`.** The interval between the two synthesized clicks is too long. Workaround: `cliclick c:X,Y c:X,Y` (chained, both single-clicks back-to-back) reliably fires the count:2 gesture.
2. **Right-click on a backgrounded Caterm hits the window underneath** (Conductor / a terminal). Always `osascript … to activate` before `cliclick rc:`.
3. **`osascript … window 1 of process caterm` returns `Invalid index (-1719)` when no window exists.** The app is alive but has no front window (closed or minimized). `open -a caterm` to call it back.
4. **`set size` is silently clamped to the screen.** Asking for 2500×700 on a 1920-wide display gets you 1130×700. Move the window to (0, 50) FIRST, then resize, so the resized frame fits.
5. **Identical screenshots after a UI action mean the action did nothing.** `md5 /tmp/before.png /tmp/after.png` — same hash → cliclick coordinate was wrong, or window wasn't focused, or gesture didn't fire. Don't proceed assuming success.
6. **Two Caterm processes can run side-by-side** under different paths (e.g. `.build/debug/caterm` and `.build/arm64-apple-macosx/debug/Caterm.app/.../caterm`). `make kill` only matches one path. Verify with `pgrep -lx caterm` and `kill <pid>` the orphans before launching the new build, otherwise you're testing stale binaries.

## End-to-end example: verifying an SFTP drawer fix

```bash
# 1. Code edit happens (Edit tool)

# 2. Rebuild + relaunch
make -C apps/macos kill
make -C apps/macos run-bg              # → "Started (pid 13708)"

sleep 3
open -a caterm
sleep 1

# 3. Pin window
osascript <<'EOF'
tell application "System Events"
  tell process "caterm"
    set position of front window to {0, 50}
    set size of front window to {1500, 700}
  end tell
end tell
EOF

# 4. Connect to host (double click sidebar row)
osascript -e 'tell application "caterm" to activate'
cliclick c:130,100 c:130,100
sleep 5

# 5. Open file drawer
osascript -e 'tell application "System Events" to keystroke "f" using {command down, shift down}'
sleep 4

# 6. Capture + inspect
screencapture -x -R 0,50,1500,700 /tmp/v-final.png
# (Read tool on /tmp/v-final.png — confirm size column shows "47 KB" etc.)
```

## Cleanup

When done, kill the test instance so the user's normal Caterm session is unaffected:

```bash
make -C apps/macos kill
pgrep -lx caterm                # should be empty
# kill any stragglers found
```

## Anti-patterns

- **Committing a UI fix without running this loop.** SwiftUI layout has many ways to compile-but-render-wrong (frame priorities, fixedSize, Spacer + List safe-area, NavigationSplitView column clamping). Code review can't catch them; only pixels can.
- **Claiming "the code looks correct" when the user pushes back.** They're seeing the rendering; you must see the rendering too.
- **Reusing prior screenshots as evidence.** A screenshot proves the state of the binary that was running THEN. After a rebuild, capture again.
