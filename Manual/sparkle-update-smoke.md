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
