# macOS Sparkle Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship in-app auto-update for the Caterm macOS app via Sparkle 2: the installed app checks a GitHub-hosted appcast, shows a standard update prompt with CHANGELOG release notes, and self-updates.

**Architecture:** Add Sparkle as an SPM dependency linked only into the `Caterm` target. A thin, protocol-injectable `UpdaterController` owns `SPUStandardUpdaterController` and is wired into the SwiftUI menu. The distribution packaging scripts derive the version from `CHANGELOG.md`, embed + deep-sign `Sparkle.framework`, and the publish script stages the `.app.zip`, converts the CHANGELOG section to HTML, runs `generate_appcast`, and uploads `appcast.xml` to the GitHub release.

**Tech Stack:** Swift / SwiftUI, Sparkle 2 (SPM binary target), bash packaging/signing scripts, `generate_appcast` / EdDSA keychain key, `gh` CLI, GitHub Releases.

**Reference spec:** `docs/superpowers/specs/2026-05-19-macos-sparkle-auto-update-design.md`

---

## File Structure

**Created:**
- `Sources/Caterm/Updates/UpdaterDriving.swift` — protocol abstracting the subset of `SPUUpdater` the app uses (testable seam).
- `Sources/Caterm/Updates/UpdaterController.swift` — `@MainActor` `ObservableObject` wrapping production Sparkle; injectable for tests.
- `Tests/CatermTests/UpdaterControllerTests.swift` — unit tests with a fake `UpdaterDriving`.
- `Scripts/lib-version.sh` — sourced helper: `caterm_changelog_version` (skip `[Unreleased]`) + `caterm_build_number`.
- `Scripts/lib-sparkle.sh` — sourced helper: `find_sparkle_framework`, `find_sparkle_tool` (locate `generate_appcast`).
- `Scripts/lib-md2html.sh` — sourced helper: `caterm_md_to_html` (CHANGELOG-subset markdown → minimal HTML document).
- `Scripts/sparkle_public_key.txt` — committed Sparkle EdDSA **public** key (safe to commit; injected into the bundle Info.plist).
- `Scripts/tests/test-lib-version.sh` — standalone bash test for `lib-version.sh`.
- `Scripts/tests/test-lib-md2html.sh` — standalone bash test for `lib-md2html.sh`.
- `Manual/sparkle-update-smoke.md` — manual GUI smoke checklist.

**Modified:**
- `Package.swift:14-17` (deps) and `Package.swift:147-182` (`Caterm` target deps) — add Sparkle.
- `Sources/Caterm/CatermApp.swift` — own an `UpdaterController`, add a "Check for Updates…" menu command.
- `Scripts/release.sh:270-272` — derive version/build from CHANGELOG via `lib-version.sh`.
- `Scripts/dist-package.sh:51-52, 117-163, 191-196` — version from CHANGELOG, Sparkle Info.plist keys, embed + deep-sign `Sparkle.framework`.
- `Scripts/dev-run-app.sh` (Info.plist heredoc ~`:89-114`) — add Sparkle keys so dev builds can exercise the updater.
- `Scripts/publish-release.sh:62-64, 86-156` — staging dir, HTML notes, `generate_appcast`, extra assets, `--draft` guard, Sparkle-signature gate.
- `Makefile` `doctor:` target (`:242-252`) — Sparkle diagnostics.
- `README.md`, `docs/macos-dev-signing.md` — one-time key setup + first-release caveat.
- `.gitignore` — ignore Sparkle private-key export under `sign/`.

---

## Decisions locked by this plan (resolving spec "二选一" items)

1. **Release-notes format:** CHANGELOG-subset markdown → **minimal HTML document** via a no-new-dependency awk converter (`lib-md2html.sh`). We do NOT use the `.md` + Sparkle-2.9 path.
2. **Public key delivery:** `generate_keys` (manual one-time) → public key string committed to `Scripts/sparkle_public_key.txt`; `dist-package.sh` / `dev-run-app.sh` read that file into the Info.plist `SUPublicEDKey`. Private key stays in the login Keychain.
3. **Sparkle component signing:** keep the full `Sparkle.framework`, deep-sign every nested executable inside-out with `CATERM_DIST_IDENTITY --options runtime --timestamp`, then seal the outer `.app`. No XPC removal.

---

## Task 1: Add Sparkle SPM dependency

**Files:**
- Modify: `Package.swift:14-17`, `Package.swift:147-182`

- [ ] **Step 1: Add the package dependency**

In `Package.swift`, change the `dependencies:` array (currently lines 14-17) to:

```swift
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
```

- [ ] **Step 2: Link Sparkle into the `Caterm` target only**

In the `.executableTarget(name: "Caterm", ...)` block, add Sparkle to its `dependencies:` array (after `"SnippetSyncClient",` on line 164). The array becomes:

```swift
            dependencies: [
                "TerminalEngine",
                "SSHCommandBuilder",
                "SessionStore",
                "KeychainStore",
                "ConfigStore",
                "ServerSyncClient",
                "HostSyncStore",
                "FileTransferStore",
                "SFTPCommandBuilder",
                "CloudKitSyncClient",
                "CredentialSync",
                "CredentialSyncStore",
                "SettingsSyncStore",
                "SnippetStore",
                "SnippetSyncClient",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
```

Do NOT add Sparkle to `CatermMobileApp`, `CatermMobile`, or any library/test target — Sparkle is macOS-only and linking it into the iOS target breaks the iOS build.

- [ ] **Step 3: Resolve and build**

Run: `swift build --target Caterm 2>&1 | tail -20`
Expected: build succeeds; Sparkle resolves. (First resolve downloads the binary artifact; this can take a minute.)

- [ ] **Step 4: Confirm iOS target still compiles**

Run: `swift build --target CatermMobileApp 2>&1 | tail -5`
Expected: build succeeds (no Sparkle symbols pulled in).

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add Sparkle SPM dependency to Caterm target"
```

---

## Task 2: `UpdaterDriving` protocol + `UpdaterController` wrapper

**Files:**
- Create: `Sources/Caterm/Updates/UpdaterDriving.swift`
- Create: `Sources/Caterm/Updates/UpdaterController.swift`
- Test: `Tests/CatermTests/UpdaterControllerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/CatermTests/UpdaterControllerTests.swift`:

```swift
import XCTest
@testable import Caterm

@MainActor
final class UpdaterControllerTests: XCTestCase {
    final class FakeUpdater: UpdaterDriving {
        var canCheck = true
        private(set) var checkCount = 0
        var canCheckForUpdates: Bool { canCheck }
        func checkForUpdates() { checkCount += 1 }
    }

    func testCheckForUpdatesForwardsToDriver() {
        let fake = FakeUpdater()
        let controller = UpdaterController(updater: fake)
        controller.checkForUpdates()
        controller.checkForUpdates()
        XCTAssertEqual(fake.checkCount, 2)
    }

    func testCanCheckForUpdatesPassesThrough() {
        let fake = FakeUpdater()
        let controller = UpdaterController(updater: fake)
        fake.canCheck = false
        XCTAssertFalse(controller.canCheckForUpdates)
        fake.canCheck = true
        XCTAssertTrue(controller.canCheckForUpdates)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter UpdaterControllerTests 2>&1 | tail -15`
Expected: FAIL — `UpdaterDriving` / `UpdaterController` undefined.

- [ ] **Step 3: Create the protocol**

Create `Sources/Caterm/Updates/UpdaterDriving.swift`:

```swift
import Foundation

/// The subset of `SPUUpdater` the app drives. Abstracted so the menu/UI
/// logic is unit-testable without booting a real Sparkle updater (which
/// reads the bundle Info.plist and warns when SUFeedURL/SUPublicEDKey
/// are absent in a test bundle).
@MainActor
protocol UpdaterDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}
```

- [ ] **Step 4: Create the controller**

Create `Sources/Caterm/Updates/UpdaterController.swift`:

```swift
import Combine
import Foundation
import Sparkle

/// Owns the Sparkle updater and exposes only what the menu needs.
/// Production path constructs `SPUStandardUpdaterController(startingUpdater:
/// true, ...)`, which begins background scheduled checks immediately
/// (cadence governed by Info.plist `SUEnableAutomaticChecks` /
/// `SUScheduledCheckInterval`). Tests inject a fake `UpdaterDriving`.
@MainActor
final class UpdaterController: ObservableObject {
    private let updater: any UpdaterDriving

    /// Test/explicit-injection initializer.
    init(updater: any UpdaterDriving) {
        self.updater = updater
    }

    /// Production initializer: boots the real Sparkle updater.
    convenience init() {
        self.init(updater: SparkleUpdaterAdapter())
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    func checkForUpdates() { updater.checkForUpdates() }
}

/// Adapts `SPUStandardUpdaterController` to `UpdaterDriving`.
@MainActor
private final class SparkleUpdaterAdapter: UpdaterDriving {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter UpdaterControllerTests 2>&1 | tail -15`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/Caterm/Updates Tests/CatermTests/UpdaterControllerTests.swift
git commit -m "feat: add testable UpdaterController wrapping Sparkle"
```

---

## Task 3: Wire "Check for Updates…" into the app menu

**Files:**
- Modify: `Sources/Caterm/CatermApp.swift`

- [ ] **Step 1: Hold the controller as app state**

In `Sources/Caterm/CatermApp.swift`, add a stored `@StateObject` next to the others (after line 36 `@StateObject private var commandKeyMonitor = CommandKeyMonitor()`):

```swift
	@StateObject private var updaterController = UpdaterController()
```

`UpdaterController()` (the no-arg convenience init) boots Sparkle once when the scene is created. No work is needed in `CatermApp.init()`.

- [ ] **Step 2: Add the menu command**

In the `.commands { ... }` block, add a new `CommandGroup` immediately after the `CommandGroup(replacing: .appSettings) { ... }` block (it currently ends at line 352 `.keyboardShortcut(",", modifiers: .command) }`). Insert:

```swift
			// Sparkle "Check for Updates…" under the app menu, just after
			// "About". The button disables itself while an update check is
			// already in flight (Sparkle's canCheckForUpdates).
			CommandGroup(after: .appInfo) {
				Button("Check for Updates…") {
					updaterController.checkForUpdates()
				}
				.disabled(!updaterController.canCheckForUpdates)
			}
```

- [ ] **Step 3: Build the app**

Run: `swift build --target Caterm 2>&1 | tail -10`
Expected: build succeeds.

- [ ] **Step 4: Run the full Caterm test target (no regressions)**

Run: `swift test --filter CatermTests 2>&1 | tail -15`
Expected: PASS (existing tests + UpdaterControllerTests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Caterm/CatermApp.swift
git commit -m "feat: add Check for Updates menu command"
```

---

## Task 4: `lib-version.sh` — CHANGELOG → version + monotonic build number

**Files:**
- Create: `Scripts/lib-version.sh`
- Create: `Scripts/tests/test-lib-version.sh`

- [ ] **Step 1: Write the failing test**

Create `Scripts/tests/test-lib-version.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib-version.sh"

fail=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "ok   - $desc"
    else
        echo "FAIL - $desc (expected '$expected', got '$actual')"
        fail=1
    fi
}

tmp="$(mktemp)"
cat > "$tmp" <<'EOF'
# Changelog
## [Unreleased]
## [1.1.0] - 2026-05-17
notes
## [1.0.0] - 2026-01-01
EOF

check "version skips [Unreleased]" "1.1.0" "$(caterm_changelog_version "$tmp")"
check "build number 1.1.0"  "10100" "$(caterm_build_number 1.1.0)"
check "build number 1.2.3"  "10203" "$(caterm_build_number 1.2.3)"
check "build number 0.9.0"  "900"   "$(caterm_build_number 0.9.0)"
check "build number 1.10.2" "11002" "$(caterm_build_number 1.10.2)"

if caterm_build_number 1.100.0 2>/dev/null; then
    echo "FAIL - segment >=100 must error"; fail=1
else
    echo "ok   - segment >=100 errors"
fi

rm -f "$tmp"
exit "$fail"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash Scripts/tests/test-lib-version.sh; echo "exit=$?"`
Expected: FAIL — `lib-version.sh` not found / functions undefined.

- [ ] **Step 3: Implement the library**

Create `Scripts/lib-version.sh`:

```bash
# lib-version.sh — sourced helpers. No side effects on source.
#
#   caterm_changelog_version [CHANGELOG_PATH]
#       Echo the first `## [X.Y.Z]` release version, skipping
#       `## [Unreleased]`. Mirrors publish-release.sh's existing grep.
#
#   caterm_build_number X.Y.Z
#       Echo a strictly-monotonic CFBundleVersion = X*10000 + Y*100 + Z.
#       Each segment must be < 100; otherwise error to stderr + return 1.

caterm_changelog_version() {
    local changelog="${1:-CHANGELOG.md}"
    local v
    v="$(grep -m1 -E '^## \[[0-9]' "$changelog" \
        | sed -E 's/^## \[([^]]+)\].*/\1/')"
    if [[ -z "$v" ]]; then
        echo "lib-version: no '## [X.Y.Z]' release entry in $changelog" >&2
        return 1
    fi
    printf '%s' "$v"
}

caterm_build_number() {
    local semver="$1"
    if [[ ! "$semver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        echo "lib-version: not a X.Y.Z version: '$semver'" >&2
        return 1
    fi
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    local patch="${BASH_REMATCH[3]}"
    local seg
    for seg in "$major" "$minor" "$patch"; do
        if (( seg >= 100 )); then
            echo "lib-version: version segment >=100 ('$semver') breaks the build-number scheme" >&2
            return 1
        fi
    done
    printf '%s' "$(( major * 10000 + minor * 100 + patch ))"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash Scripts/tests/test-lib-version.sh; echo "exit=$?"`
Expected: all `ok`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add Scripts/lib-version.sh Scripts/tests/test-lib-version.sh
git commit -m "feat: add CHANGELOG version + monotonic build-number helper"
```

---

## Task 5: `lib-md2html.sh` — CHANGELOG-subset markdown → minimal HTML

**Files:**
- Create: `Scripts/lib-md2html.sh`
- Create: `Scripts/tests/test-lib-md2html.sh`

- [ ] **Step 1: Write the failing test**

Create `Scripts/tests/test-lib-md2html.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib-md2html.sh"

fail=0
md="$(mktemp)"; html="$(mktemp)"
cat > "$md" <<'EOF'
### iOS app (new)

- First bullet with <angle> & ampersand
- Second bullet

A trailing paragraph.
EOF

caterm_md_to_html "$md" > "$html"

grep -q "<!DOCTYPE html>" "$html"            || { echo "FAIL - no doctype"; fail=1; }
grep -q "<h3>iOS app (new)</h3>" "$html"     || { echo "FAIL - h3 not converted"; fail=1; }
grep -q "<ul>" "$html"                       || { echo "FAIL - no <ul>"; fail=1; }
grep -q "<li>First bullet with &lt;angle&gt; &amp; ampersand</li>" "$html" \
                                             || { echo "FAIL - bullet/escaping wrong"; fail=1; }
grep -q "<p>A trailing paragraph.</p>" "$html" || { echo "FAIL - paragraph not wrapped"; fail=1; }
[[ "$fail" -eq 0 ]] && echo "ok - md2html"

rm -f "$md" "$html"
exit "$fail"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash Scripts/tests/test-lib-md2html.sh; echo "exit=$?"`
Expected: FAIL — `lib-md2html.sh` not found.

- [ ] **Step 3: Implement the converter**

Create `Scripts/lib-md2html.sh`:

```bash
# lib-md2html.sh — sourced helper.
#
#   caterm_md_to_html MARKDOWN_PATH
#       Convert the CHANGELOG subset we actually emit (### headings,
#       "- " bullets, blank-line-separated paragraphs) to a minimal,
#       self-contained HTML document on stdout. HTML-escapes & < > so
#       release notes render correctly inside Sparkle's WebKit view.

caterm_md_to_html() {
    local src="$1"
    printf '%s\n' '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>'
    awk '
        function esc(s) {
            gsub(/&/, "\\&amp;", s)
            gsub(/</, "\\&lt;", s)
            gsub(/>/, "\\&gt;", s)
            return s
        }
        function closelist() { if (inlist) { print "</ul>"; inlist=0 } }
        function closepara() { if (inpara) { print "</p>"; inpara=0 } }
        /^### / {
            closelist(); closepara()
            print "<h3>" esc(substr($0, 5)) "</h3>"
            next
        }
        /^[[:space:]]*-[[:space:]]+/ {
            closepara()
            if (!inlist) { print "<ul>"; inlist=1 }
            line=$0
            sub(/^[[:space:]]*-[[:space:]]+/, "", line)
            print "<li>" esc(line) "</li>"
            next
        }
        /^[[:space:]]*$/ {
            closelist(); closepara()
            next
        }
        {
            closelist()
            if (!inpara) { print "<p>"; inpara=1; print esc($0) }
            else { print esc($0) }
            next
        }
        END { closelist(); closepara() }
    ' "$src"
    printf '%s\n' '</body></html>'
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash Scripts/tests/test-lib-md2html.sh; echo "exit=$?"`
Expected: `ok - md2html`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add Scripts/lib-md2html.sh Scripts/tests/test-lib-md2html.sh
git commit -m "feat: add CHANGELOG markdown to minimal HTML converter"
```

---

## Task 6: `lib-sparkle.sh` — locate framework + tools

**Files:**
- Create: `Scripts/lib-sparkle.sh`

- [ ] **Step 1: Implement the discovery helper**

Create `Scripts/lib-sparkle.sh`:

```bash
# lib-sparkle.sh — sourced helper. Locates SwiftPM-fetched Sparkle
# artifacts. Sparkle is a binary target: paths under .build are NOT
# stable across SwiftPM/config versions, so we search + assert
# uniqueness instead of hardcoding.
#
#   find_sparkle_framework ROOT
#       Echo the absolute path of the single Sparkle.framework under
#       ROOT/.build. Error + return 1 if zero or multiple are found,
#       or if it lacks the host architecture.
#
#   find_sparkle_tool ROOT TOOLNAME
#       Echo the absolute path of a Sparkle CLI tool (generate_appcast,
#       generate_keys, sign_update). Error + return 1 if not found.

find_sparkle_framework() {
    local root="$1"
    local matches
    matches="$(find "$root/.build" -name 'Sparkle.framework' -type d 2>/dev/null \
        | grep -v '/Sparkle.framework/.*Sparkle.framework' || true)"
    local count
    count="$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$count" -eq 0 ]]; then
        echo "lib-sparkle: Sparkle.framework not found under $root/.build (run 'swift build' first)" >&2
        return 1
    fi
    if [[ "$count" -ne 1 ]]; then
        echo "lib-sparkle: expected exactly one Sparkle.framework, found $count:" >&2
        printf '%s\n' "$matches" >&2
        return 1
    fi
    local fw
    fw="$(printf '%s\n' "$matches" | sed '/^$/d' | head -1)"
    local arch
    arch="$(uname -m)"
    if ! lipo -info "$fw/Versions/Current/Sparkle" 2>/dev/null | grep -q "$arch" \
       && ! file "$fw/Versions/Current/Sparkle" 2>/dev/null | grep -q "$arch"; then
        echo "lib-sparkle: $fw does not contain host arch $arch" >&2
        return 1
    fi
    printf '%s' "$fw"
}

find_sparkle_tool() {
    local root="$1" tool="$2"
    local matches
    matches="$(find "$root/.build" -name "$tool" -type f -perm +111 2>/dev/null || true)"
    local hit
    hit="$(printf '%s\n' "$matches" | sed '/^$/d' | head -1)"
    if [[ -z "$hit" ]]; then
        echo "lib-sparkle: tool '$tool' not found under $root/.build." >&2
        echo "             It ships in the Sparkle SPM artifact; run 'swift build' first," >&2
        echo "             or download Sparkle's release tools bundle." >&2
        return 1
    fi
    printf '%s' "$hit"
}
```

- [ ] **Step 2: Smoke-check discovery against a built tree**

Run:
```bash
swift build --target Caterm >/dev/null 2>&1; \
bash -c 'source Scripts/lib-sparkle.sh; find_sparkle_framework "$(pwd)"; echo; find_sparkle_tool "$(pwd)" generate_appcast'
```
Expected: prints one `…/Sparkle.framework` path and one `…/generate_appcast` path, no error. (If `generate_appcast` is not present in the SPM artifact on this Sparkle version, note it — Task 9 Step 2 has the fallback documented.)

- [ ] **Step 3: Commit**

```bash
git add Scripts/lib-sparkle.sh
git commit -m "feat: add Sparkle framework/tool discovery helper"
```

---

## Task 7: Generate EdDSA keys + record the public key (one-time setup)

**Files:**
- Create: `Scripts/sparkle_public_key.txt`
- Modify: `.gitignore`

> This task runs `generate_keys` once. The **private** key is stored in the
> login Keychain by Sparkle and must never be committed. The **public** key
> is safe to commit and is what the app embeds.

- [ ] **Step 1: Ignore any private-key export**

Append to `.gitignore`:

```
# Sparkle EdDSA private key export (public key lives in Scripts/sparkle_public_key.txt)
sign/sparkle_ed_private_key*
```

- [ ] **Step 2: Locate and run `generate_keys`**

Run:
```bash
swift build --target Caterm >/dev/null 2>&1; \
GENKEYS="$(bash -c 'source Scripts/lib-sparkle.sh; find_sparkle_tool "$(pwd)" generate_keys')"; \
echo "generate_keys: $GENKEYS"; \
"$GENKEYS"
```
Expected: prints a public key line like
`<string>BASE64PUBLICKEY…</string>` (and, on first run, stores the private key in the Keychain). If a key already exists it prints the existing public key.

- [ ] **Step 3: Record the public key**

Create `Scripts/sparkle_public_key.txt` containing **only** the base64 public key string from Step 2 (no XML tags, no whitespace/newline beyond a trailing newline). Example content:

```
BASE64PUBLICKEYFROMSTEP2
```

- [ ] **Step 4: Back up the private key (manual, not committed)**

Run:
```bash
mkdir -p sign
SIGNUPDATE="$(bash -c 'source Scripts/lib-sparkle.sh; find_sparkle_tool "$(pwd)" generate_keys')"; \
"$SIGNUPDATE" -x sign/sparkle_ed_private_key.txt; \
echo "Private key exported to sign/sparkle_ed_private_key.txt (gitignored). Store it in your password manager, then you may delete the file."
```
Expected: `sign/sparkle_ed_private_key.txt` created and gitignored (verify `git status --porcelain sign/` shows nothing).

- [ ] **Step 5: Commit (public key only)**

```bash
git add Scripts/sparkle_public_key.txt .gitignore
git commit -m "chore: add Sparkle EdDSA public key + ignore private export"
```

---

## Task 8: Distribution packaging — version, Info.plist keys, framework embed + sign

**Files:**
- Modify: `Scripts/dist-package.sh`
- Modify: `Scripts/dev-run-app.sh`
- Modify: `Scripts/release.sh`

- [ ] **Step 1: Derive version + build number from CHANGELOG in `release.sh`**

In `Scripts/release.sh`, replace lines 270-272:

```bash
VERSION="${CATERM_DIST_VERSION:-1.0.0}"
export CATERM_DIST_VERSION="$VERSION"
export CATERM_DIST_BUILD="${CATERM_DIST_BUILD:-1}"
```

with:

```bash
# Version/build are derived from CHANGELOG.md (single source of truth).
# Sparkle compares CFBundleVersion; a constant build number means
# auto-update never detects a new release.
# shellcheck disable=SC1091
source "$SCRIPTS/lib-version.sh"
VERSION="${CATERM_DIST_VERSION:-$(caterm_changelog_version "$ROOT/CHANGELOG.md")}"
export CATERM_DIST_VERSION="$VERSION"
export CATERM_DIST_BUILD="${CATERM_DIST_BUILD:-$(caterm_build_number "$VERSION")}"
```

- [ ] **Step 2: Same derivation as a fallback in `dist-package.sh`**

In `Scripts/dist-package.sh`, replace lines 51-52:

```bash
APP_VERSION="${CATERM_DIST_VERSION:-1.0.0}"
APP_BUILD="${CATERM_DIST_BUILD:-1}"
```

with:

```bash
# shellcheck disable=SC1091
source "$ROOT/Scripts/lib-version.sh"
APP_VERSION="${CATERM_DIST_VERSION:-$(caterm_changelog_version "$ROOT/CHANGELOG.md")}"
APP_BUILD="${CATERM_DIST_BUILD:-$(caterm_build_number "$APP_VERSION")}"
```

- [ ] **Step 3: Add Sparkle keys to the dist Info.plist heredoc**

In `Scripts/dist-package.sh`, just before the `cat > "$APP/Contents/Info.plist" <<EOF` line (currently line 136), add:

```bash
SPARKLE_PUB_KEY="$(tr -d '[:space:]' < "$ROOT/Scripts/sparkle_public_key.txt")"
if [[ -z "$SPARKLE_PUB_KEY" ]]; then
    echo "Error: Scripts/sparkle_public_key.txt is empty (run Task 7 / generate_keys)." >&2
    exit 1
fi
SPARKLE_FEED_URL="https://github.com/ZingerLittleBee/Caterm/releases/latest/download/appcast.xml"
```

Then, inside the heredoc, add these four keys immediately before the closing `</dict>` (currently line 161, after the `CFBundleIconFile`/`AppIcon` pair):

```
    <key>SUFeedURL</key>
    <string>${SPARKLE_FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUB_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
```

- [ ] **Step 4: Embed + deep-sign `Sparkle.framework` before the outer seal**

In `Scripts/dist-package.sh`, immediately **after** the provisioning-profile embed block (after line 169 `cp "$CATERM_DIST_PROFILE_PATH" "$APP/Contents/embedded.provisionprofile"`) and **before** the "Two-pass re-seal" comment (line 171), insert:

```bash
# ---------------------------------------------------------------------------
# Embed + deep-sign Sparkle.framework.
#
# SwiftPM external packaging does NOT auto-embed frameworks. Sparkle's
# nested executables (Autoupdate, Updater.app, XPCServices/*.xpc, the
# framework dylib) must each be Developer-ID signed inside-out with
# hardened runtime + secure timestamp BEFORE the outer .app seal, or
# notarization/Gatekeeper rejects the bundle.
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091
source "$ROOT/Scripts/lib-sparkle.sh"
SPARKLE_FW="$(find_sparkle_framework "$ROOT")"
echo "==> Embedding Sparkle.framework from $SPARKLE_FW"
mkdir -p "$APP/Contents/Frameworks"
/usr/bin/ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

EMBEDDED_FW="$APP/Contents/Frameworks/Sparkle.framework"
sign_one() {
    codesign --force --options runtime --timestamp \
        --sign "$CATERM_DIST_IDENTITY" "$1"
}

echo "==> Signing Sparkle nested components (inside-out)"
# XPC services first (deepest).
while IFS= read -r xpc; do
    [[ -n "$xpc" ]] && sign_one "$xpc"
done < <(find "$EMBEDDED_FW" -name '*.xpc' -type d)
# Autoupdate + the Updater.app (Sparkle 2 layout under Versions/Current).
for nested in \
    "$EMBEDDED_FW/Versions/Current/Autoupdate" \
    "$EMBEDDED_FW/Versions/Current/Updater.app"; do
    [[ -e "$nested" ]] && sign_one "$nested"
done
# Finally the framework itself.
sign_one "$EMBEDDED_FW"

echo "==> Verifying embedded Sparkle.framework signature"
codesign --verify --deep --strict --verbose=2 "$EMBEDDED_FW" 2>&1 | sed 's/^/    /'
```

> Note: the existing outer `codesign --force --sign … "$APP"` at line 192-196 seals the bundle and references these inner signatures. It must run **after** this block (it already does — this block is inserted above the re-seal section). Do not add `--deep` to the outer seal.

- [ ] **Step 5: Add the same Sparkle keys to the dev Info.plist**

In `Scripts/dev-run-app.sh`, before its `cat > "$APP/Contents/Info.plist" <<EOF` line (~`:89`), add:

```bash
SPARKLE_PUB_KEY="$(tr -d '[:space:]' < "$ROOT/Scripts/sparkle_public_key.txt" 2>/dev/null || true)"
SPARKLE_FEED_URL="https://github.com/ZingerLittleBee/Caterm/releases/latest/download/appcast.xml"
```

(Use the dev script's own root variable if it is not named `$ROOT` — read the top of `dev-run-app.sh` and match its existing path variable; the file is assembled the same way as `dist-package.sh`.) Then add the same four keys before the dev heredoc's closing `</dict>`:

```
    <key>SUFeedURL</key>
    <string>${SPARKLE_FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUB_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <false/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
```

> Dev uses `SUEnableAutomaticChecks` = `false` (manual "Check for Updates…" only) so dev runs don't nag against the public feed; the key is present so the menu item works for manual smoke.

- [ ] **Step 6: Verify scripts parse**

Run: `bash -n Scripts/release.sh && bash -n Scripts/dist-package.sh && bash -n Scripts/dev-run-app.sh && echo "syntax OK"`
Expected: `syntax OK`.

- [ ] **Step 7: Verify version derivation end-to-end (no signing)**

Run:
```bash
bash -c 'source Scripts/lib-version.sh; v=$(caterm_changelog_version CHANGELOG.md); echo "version=$v build=$(caterm_build_number "$v")"'
```
Expected: `version=1.1.0 build=10100` (matches the current top release entry in `CHANGELOG.md`).

- [ ] **Step 8: Commit**

```bash
git add Scripts/release.sh Scripts/dist-package.sh Scripts/dev-run-app.sh
git commit -m "feat: derive version from CHANGELOG, embed+sign Sparkle.framework, add Sparkle Info.plist keys"
```

---

## Task 9: Publish pipeline — staging dir, HTML notes, appcast, asset upload, guards

**Files:**
- Modify: `Scripts/publish-release.sh`

- [ ] **Step 1: Guard `--draft` and define staging paths**

In `Scripts/publish-release.sh`, after the arg-parse `while` loop (after line 40), add:

```bash
if [[ "$DRAFT" -eq 1 ]]; then
    echo "Error: --draft is incompatible with Sparkle auto-update." >&2
    echo "       The feed URL resolves via releases/latest/download/appcast.xml," >&2
    echo "       which ignores drafts/prereleases. Publish non-draft or skip publish." >&2
    exit 1
fi
```

Then, after line 64 (`APP_ZIP="$BIN_DIR/Caterm-${VERSION}-app.zip"`), add:

```bash
STAGE_DIR="$BIN_DIR/appcast-stage"
APP_ZIP_NAME="Caterm-${VERSION}-app.zip"
NOTES_HTML="$STAGE_DIR/Caterm-${VERSION}-app.html"
APPCAST="$STAGE_DIR/appcast.xml"
```

- [ ] **Step 2: After the zip step, stage + convert notes + run generate_appcast**

In `Scripts/publish-release.sh`, immediately after the zip block (after line 143 `run /usr/bin/ditto -c -k --keepParent "$APP" "$APP_ZIP"`) and before the "GitHub release + assets" section (line 145), insert:

```bash
# ---------------------------------------------------------------------------
# 5b. Sparkle appcast.
#
# generate_appcast takes an "update archives folder" — it must contain
# ONLY the update zip (+ same-basename notes file), never $BIN_DIR which
# also holds the .dmg, Caterm.app, and SwiftPM build artifacts.
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091
source "$ROOT/Scripts/lib-sparkle.sh"
# shellcheck disable=SC1091
source "$ROOT/Scripts/lib-md2html.sh"

echo "==> Verifying embedded Sparkle.framework signature (publish gate)"
SPARKLE_IN_APP="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE_IN_APP" ]] || { echo "FAIL: $SPARKLE_IN_APP missing — rebuild with updated dist-package.sh" >&2; exit 1; }
codesign --verify --deep --strict "$SPARKLE_IN_APP" 2>/dev/null \
    || { echo "FAIL: embedded Sparkle.framework signature invalid" >&2; exit 1; }

echo "==> Staging appcast inputs"
run rm -rf "$STAGE_DIR"
run mkdir -p "$STAGE_DIR"
run cp "$APP_ZIP" "$STAGE_DIR/$APP_ZIP_NAME"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] caterm_md_to_html $NOTES_FILE > $NOTES_HTML"
else
    caterm_md_to_html "$NOTES_FILE" > "$NOTES_HTML"
fi

GEN_APPCAST="$(find_sparkle_tool "$ROOT" generate_appcast)"
echo "==> generate_appcast ($GEN_APPCAST)"
run "$GEN_APPCAST" "$STAGE_DIR"

if [[ "$DRY_RUN" -eq 0 ]]; then
    [[ -f "$APPCAST" ]] || { echo "FAIL: generate_appcast did not produce $APPCAST" >&2; exit 1; }
    grep -q "sparkle:edSignature" "$APPCAST" \
        || { echo "FAIL: appcast.xml has no EdDSA signature (is the private key in the Keychain?)" >&2; exit 1; }
fi
```

- [ ] **Step 3: Upload the new assets in the release**

In `Scripts/publish-release.sh`, change the `gh release create` invocation (line 156) from:

```bash
run gh "${GH_ARGS[@]}" "$DMG" "$APP_ZIP"
```

to:

```bash
run gh "${GH_ARGS[@]}" "$DMG" "$APP_ZIP" "$APPCAST" "$NOTES_HTML"
```

- [ ] **Step 4: Verify script parses**

Run: `bash -n Scripts/publish-release.sh && echo "syntax OK"`
Expected: `syntax OK`.

- [ ] **Step 5: Dry-run the publish path (no mutations)**

Run: `bash Scripts/publish-release.sh --dry-run 2>&1 | tail -30`
Expected: it reaches the `[dry-run] gh release create …` line listing `$DMG $APP_ZIP $APPCAST $NOTES_HTML`. It may exit earlier at the Gatekeeper gate (line 76-84) if no release build exists — that is acceptable for this dry-run; the goal is to confirm the new code path is syntactically reachable and the `--draft` guard works. Also run `bash Scripts/publish-release.sh --draft --dry-run 2>&1 | tail -3` and confirm it errors with the `--draft is incompatible` message.

- [ ] **Step 6: Commit**

```bash
git add Scripts/publish-release.sh
git commit -m "feat: generate + upload Sparkle appcast in publish pipeline"
```

---

## Task 10: `make doctor` Sparkle diagnostics + regression sweep

**Files:**
- Modify: `Makefile` (`doctor:` target, lines 242-252)

- [ ] **Step 1: Add Sparkle diagnostics to `doctor`**

In `Makefile`, at the end of the `doctor:` recipe (after line 252, the `fi` closing the `caterm signature` block), append these recipe lines (use a leading TAB, matching the file's existing recipe indentation):

```make
	@echo "Sparkle public key: $$(test -s Scripts/sparkle_public_key.txt && echo present || echo MISSING)"
	@SP_APP="$(ROOT)/.build/release/Caterm.app/Contents/Frameworks/Sparkle.framework"; \
	  if [ -d "$$SP_APP" ]; then \
	    echo "Embedded Sparkle.framework: present"; \
	    codesign --verify --deep --strict "$$SP_APP" 2>&1 | sed 's/^/  /' || echo "  (signature INVALID)"; \
	  else \
	    echo "Embedded Sparkle.framework: not built yet"; \
	  fi
```

- [ ] **Step 2: Run doctor**

Run: `make doctor 2>&1 | tail -8`
Expected: prints `Sparkle public key: present` and an `Embedded Sparkle.framework:` line (likely `not built yet` unless a release build exists). No make errors.

- [ ] **Step 3: Full regression — Swift tests + shell unit tests green**

Run:
```bash
make test 2>&1 | tail -15 && \
bash Scripts/tests/test-lib-version.sh && \
bash Scripts/tests/test-lib-md2html.sh && \
echo "ALL GREEN"
```
Expected: `swift test` passes (suite stays green), both shell tests print `ok`/exit 0, final `ALL GREEN`.

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "chore: add Sparkle diagnostics to make doctor"
```

---

## Task 11: Documentation + manual smoke checklist

**Files:**
- Create: `Manual/sparkle-update-smoke.md`
- Modify: `README.md`
- Modify: `docs/macos-dev-signing.md`

- [ ] **Step 1: Write the manual smoke checklist**

Create `Manual/sparkle-update-smoke.md`:

```markdown
# Sparkle Auto-Update Smoke Checklist

Sparkle's update flow (download → verify → relaunch) cannot be reliably
automated; verify manually before shipping the FIRST Sparkle-enabled
release and whenever signing/packaging changes.

## Local feed dry-run (no GitHub)

1. Build a release: `make release ARGS=--skip-notary` (signed, local-only).
2. Bump `CHANGELOG.md` to a higher version locally, rebuild a second
   `.app.zip`, and run `generate_appcast` against a scratch staging dir.
3. Serve it: `cd <stage> && python3 -m http.server 8000`.
4. Temporarily point a built `.app`'s `Contents/Info.plist` `SUFeedURL`
   at `http://localhost:8000/appcast.xml`.
5. Launch the OLD-version app, menu → **Check for Updates…**.
6. Expect: update window appears with CHANGELOG release notes rendered;
   "Install Update" downloads, the EdDSA signature verifies, the app
   relaunches on the new version.

## Production verification (after first publish)

1. Install the published `.app` (from the GitHub release `.dmg`).
2. Confirm `https://github.com/ZingerLittleBee/Caterm/releases/latest/download/appcast.xml`
   resolves and is signed (`sparkle:edSignature` present).
3. With a deliberately older local build, **Check for Updates…** → the
   prompt offers the published version.

## First-release caveat

Builds installed BEFORE Sparkle existed have no updater — the first
Sparkle release must be distributed manually (announce the `.dmg`).
Auto-update works from that version onward.
```

- [ ] **Step 2: Document one-time key setup in `docs/macos-dev-signing.md`**

Append a `## Sparkle auto-update` section to `docs/macos-dev-signing.md` covering: run `generate_keys` once (Task 7), private key lives in the login Keychain (never committed), public key is `Scripts/sparkle_public_key.txt`, losing the private key means no future auto-updates (back it up to a password manager), and the first Sparkle release ships manually. Keep it factual and concise; mirror the wording in `Manual/sparkle-update-smoke.md` "First-release caveat".

- [ ] **Step 3: Reference auto-update in the README Release section**

In `README.md`, in the Release/publish area, add a short note: releases now publish `appcast.xml` and the app self-updates via Sparkle; version + build number are derived from the top `## [X.Y.Z]` CHANGELOG entry (no manual `CATERM_DIST_VERSION`); `--draft` is unsupported for published releases. Match the README's existing tone/structure — read the current Release section first and slot it in, don't restructure.

- [ ] **Step 4: Commit**

```bash
git add Manual/sparkle-update-smoke.md docs/macos-dev-signing.md README.md
git commit -m "docs: document Sparkle auto-update setup, release flow, smoke checklist"
```

---

## Self-Review

**Spec coverage:**
- Sparkle SPM dep, Caterm-only link → Task 1 ✔
- `UpdaterController` + injectable protocol + menu command + tests → Tasks 2, 3 ✔
- Info.plist keys in the *generated* dist plist (+ dev plist) → Task 8 Steps 3, 5 ✔
- Embed `Sparkle.framework` (find helper, ditto, rpath note) → Task 6, Task 8 Step 4 ✔
- Inside-out deep signing + hardened runtime + timestamp → Task 8 Step 4 ✔
- EdDSA key management (generate_keys, Keychain private, committed public) → Task 7 ✔
- enclosure EdDSA signature only; `SURequireSignedFeed` not enabled → Task 9 (no SURequireSignedFeed key added) ✔
- Version from first `## [X.Y.Z]` (skip Unreleased) + monotonic build number → Task 4, Task 8 Steps 1-2 ✔
- Publish: staging dir, markdown→HTML notes, generate_appcast on staging, extra assets, `--draft` guard, Sparkle-signature gate → Task 9 ✔
- Error handling: empty public key, missing tool, missing/invalid signature, no edSignature → Tasks 8/9 guards ✔
- Tests: shell unit tests for version + md2html, Swift wrapper test with fake, `make test` green, `make doctor` Sparkle check, manual smoke → Tasks 4, 5, 2, 10, 11 ✔
- Docs (README + macos-dev-signing) → Task 11 ✔
- "不做": no CI, no delta, no silent install/settings toggle, no SURequireSignedFeed, no XPC removal, no iOS → none introduced ✔

**Placeholder scan:** No TBD/TODO; every code/script step contains full content. Doc steps (Task 11 Steps 2-3) intentionally describe content to slot into existing prose rather than dictating exact final text, since they must match existing README/doc structure that the implementer reads in-context — acceptable for docs, not code.

**Type/name consistency:** `UpdaterDriving` (`canCheckForUpdates`, `checkForUpdates()`) is defined in Task 2 Step 3 and consumed identically by `UpdaterController` (Task 2 Step 4), the fake (Task 2 Step 1), and the menu (Task 3 Step 2). Shell helpers `caterm_changelog_version` / `caterm_build_number` / `caterm_md_to_html` / `find_sparkle_framework` / `find_sparkle_tool` are defined once (Tasks 4-6) and sourced with consistent signatures in Tasks 8-10. Staging variables (`STAGE_DIR`, `APPCAST`, `NOTES_HTML`, `APP_ZIP_NAME`) are defined in Task 9 Step 1 and used in Steps 2-3.

**Known dependency:** Tasks 8-9 assume Sparkle's SPM artifact contains the CLI tools (`generate_keys`, `generate_appcast`). Task 6 Step 2 and Task 7 Step 2 verify this early; if absent on the pinned Sparkle version, the fix is to download Sparkle's release tools bundle and point `find_sparkle_tool` at it — flagged in `lib-sparkle.sh`'s error message and Task 6 Step 2 note. This is surfaced, not hidden.
