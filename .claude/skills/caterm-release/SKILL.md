---
name: caterm-release
description: |
  End-to-end release flow for the Caterm macOS/iOS app: bump version,
  build + notarize, push tag, and create the GitHub release with
  artifacts. Triggers when the user asks to "发布" / "出一个 release" /
  "release vX.Y.Z" / "推 tag" / "build and publish", or invokes
  /release-version on this repo.

  Use this INSTEAD of the generic /release-version skill — Caterm is a
  Swift Package Manager app with NO package.json / Cargo.toml /
  tauri.conf.json. The release version is driven by the top
  `## [X.Y.Z]` entry in CHANGELOG.md, not those files. Captures the
  project-specific traps (CATERM_DIST_VERSION default, push-before-publish
  gate) that will silently break a release if missed.
---

# Caterm Release (macOS + iOS)

The whole chain is two make targets — `make release` then `make publish`
— but three project-specific traps will silently break it. Read the
traps first.

## Traps (read before running)

1. **`make release` defaults the build version to `1.0.0`.**
   `Scripts/release.sh` uses `${CATERM_DIST_VERSION:-1.0.0}` and does
   **not** read CHANGELOG.md or Resources/Info.plist. If you don't pass
   `CATERM_DIST_VERSION=X.Y.Z` it produces `Caterm-1.0.0.dmg` with
   bundle version 1.0.0, and `make publish` (which derives the version
   from CHANGELOG) then fails looking for `Caterm-X.Y.Z.dmg`.
   **Always run:** `CATERM_DIST_VERSION=X.Y.Z make release`.

2. **`make publish` hard-requires HEAD already on `origin/main`.**
   `Scripts/publish-release.sh` aborts unless the tree is clean and
   `HEAD` is an ancestor of `origin/main` (the tag must point at a
   commit reviewers can see). Push the version-bump commit *before*
   publishing.

3. **Version source of truth is CHANGELOG.md.** `publish-release.sh`
   takes the version from the first `## [X.Y.Z]` heading and extracts
   that section verbatim as the GitHub release notes. No `## [X.Y.Z]`
   section ⇒ no release. The bare `## [Unreleased]` heading is skipped
   (regex requires a digit).

## Steps

Given a target version `X.Y.Z` (strip any leading `v`):

### 1. Bump version files

- **`CHANGELOG.md`**: insert a new section above the previous version:

  ```
  ## [X.Y.Z] - YYYY-MM-DD
  ```

  (use today's date). Group changes under `###` subsections
  (`### iOS app`, `### SSH & hosts`, `### Fixes`, `### Distribution`,
  …) matching the 1.0.0 / 1.1.0 style. Then add a link-ref line next to
  the existing ones at the bottom:

  ```
  [X.Y.Z]: https://github.com/ZingerLittleBee/Caterm/releases/tag/vX.Y.Z
  ```

  To draft the entry, gather commits with
  `git log v<prev>..HEAD --oneline --no-merges` and categorize by
  conventional-commit type (`feat:`→features, `fix:`/`refactor:`→fixes).
  Present the drafted entry to the user for confirmation before writing.

- **`Resources/Info.plist`**: bump
  `CFBundleShortVersionString` to `X.Y.Z` (leave `CFBundleVersion`
  unless the user wants the build number bumped too). This is the
  macOS app bundle version.

- The CHANGELOG intro line covers **macOS and iOS** since 1.1.0 — keep
  it that way.

### 2. Commit + push

```bash
git add CHANGELOG.md Resources/Info.plist
git commit -m "chore: bump version to vX.Y.Z"
git push origin main
```

Pushing to `main` and (later) the tag/GitHub release are
shared-state actions — confirm with the user before the first run
unless they've already asked for the full publish.

### 3. Build + notarize (long-running)

```bash
CATERM_DIST_VERSION=X.Y.Z make release
```

This runs build → dist codesign → notarize (round-trip to Apple) →
staple → DMG → Gatekeeper assessment. The notarization wait is several
minutes, so run it in the background and wait for completion rather
than polling. Signing/notarization env lives in `sign/`
(`Caterm_Developer_ID.provisionprofile`, `env.sh` with `APPLE_ID` /
`APPLE_TEAM_ID`; notary keychain profile defaults to `caterm`).

Confirm success before publishing:
- log ends with `status: Accepted`, `The staple and validate action
  worked!`, and `Gatekeeper assessment … accepted`
- `.build/release/Caterm.app` and `.build/release/Caterm-X.Y.Z.dmg`
  both exist

Swift 6 concurrency warnings in the build log are non-fatal and do
not block the release.

### 4. Tag + GitHub release + artifacts

```bash
make publish
```

`publish-release.sh` then: re-verifies notarization/stapling
(Gatekeeper hard gate), extracts the `## [X.Y.Z]` CHANGELOG section as
notes, creates + pushes annotated tag `vX.Y.Z`, `ditto`-zips the
`.app` (preserving the stapled ticket), and runs `gh release create`
uploading `Caterm-X.Y.Z.dmg` + `Caterm-X.Y.Z-app.zip`.

Useful flags: `make publish ARGS=--dry-run` (mutate nothing),
`make publish ARGS=--draft` (private draft release).

### 5. Verify

```bash
gh release view vX.Y.Z --json url,isDraft,assets \
  -q '"\(.url) draft=\(.isDraft)\n" + (.assets|map(.name)|join("\n"))'
```

Expect `draft=false` and both `Caterm-X.Y.Z.dmg` and
`Caterm-X.Y.Z-app.zip` attached.

## Reference: make targets

- `make release` — full pipeline; `ARGS=--skip-notary` (signed-only,
  two-Mac smoke) / `ARGS=--skip-dmg` (.app only).
- `make publish` — tag + GitHub release + upload; gated on
  notarized+stapled artifacts.
