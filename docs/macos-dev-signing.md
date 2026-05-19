# macOS Dev Signing for CloudKit Builds

Local-launch signing notes for the Caterm macOS app once it depends on CloudKit (or any other AMFI-restricted entitlement). `swift run`-style unsigned launches stop working the moment `com.apple.developer.icloud-services` is in the entitlements — AMFI refuses to load the binary unless every link in the chain (cert → profile → device → entitlements) lines up.

These are the pitfalls that ate hours during Plan A. Read this before adding another restricted entitlement (Push, App Groups, Keychain Sharing, etc.).

## Prerequisites

You need all five from the plan's "Pre-flight setup" section in `docs/superpowers/plans/2026-05-02-cloudkit-host-sync.md`:
1. iCloud container registered.
2. Dev Mac registered with **Provisioning UDID** (not Hardware UUID).
3. **Apple Development** cert (not Developer ID) installed in keychain.
4. **Mac App Development** profile (not Developer ID profile), tying cert + device + container.
5. CloudKit Dashboard schema indexes (Queryable on `recordName` for Host record type).

## Pitfall 1 — Apple Silicon: Provisioning UDID ≠ Hardware UUID

`system_profiler SPHardwareDataType` shows two values:

```
Hardware UUID:        76F7845C-...
Provisioning UDID:    00006031-0012316C2623001C
```

When registering the device in the Apple Developer Portal, **use the Provisioning UDID**. AMFI on Apple Silicon validates against this; using Hardware UUID by mistake gives:

```
amfid: No matching profile found
```

with no further hint that the device id is the cause.

## Pitfall 2 — Cert team disambiguation

`security find-identity -v -p codesigning` lists certs by Common Name. Two certs with the same CN can exist in different Apple Developer teams — Xcode happily creates them in whichever team you last selected. Verify the team via the OU= field:

```bash
security find-certificate -c "Apple Development: <name>" -p \
  | openssl x509 -noout -subject
# subject=UID=..., CN=Apple Development: <name> (XXXXXXXXXX), OU=9VM4RM39R3, ...
```

The OU is the team id. The trailing `(XXXXXXXXXX)` after CN is the cert id, not the team — they are not the same.

If the cert's OU doesn't match the team that owns the iCloud container, AMFI will load the profile but reject the binary because the cert's team doesn't match the profile's team:

```
amfid: code signature validation failed fatally: ... cert SHA1 mismatch
```

Fix: create the cert again from inside Xcode while the correct team is selected in Settings → Accounts.

## Pitfall 3 — Distribution certs need notarization

A Developer ID Application cert *is* a valid signing identity, but Gatekeeper won't accept Developer-ID-signed binaries that haven't been notarized — they fail to launch with the same fatal AMFI error. For dev iteration always use **Apple Development**, never **Developer ID Application**.

## Pitfall 4 — Profile type must match what you want to run

Two profile types pair with an Apple Development cert:

| Profile type            | CloudKit env(s) allowed | Notarization required |
|-------------------------|-------------------------|-----------------------|
| Mac App Development     | Development + Production | No                    |
| Developer ID            | Production only          | Yes                   |

Use **Mac App Development**. The signed app then opts into a CloudKit environment via the entitlements key:

```xml
<key>com.apple.developer.icloud-container-environment</key>
<string>Development</string>
```

(Use `Development` until the schema is deployed to Production.)

## Pitfall 5 — Outer codesign on a bundle drops `--entitlements`

`codesign` recursively re-signs nested binaries inside an `.app`, but a bundle-level `codesign --sign … MyApp.app` invocation that doesn't pass `--entitlements` will re-sign the **main executable** with empty entitlements — even if you previously signed the inner binary with the right entitlements. The app then crashes at launch with:

```
EXC_BREAKPOINT in CKContainer init
```

because `com.apple.developer.icloud-services` is no longer present on the running binary.

Fix: pass `--entitlements /tmp/Caterm-substituted.entitlements` to **every** `codesign` invocation, including the outer bundle one.

## Pitfall 6 — `application-identifier` is not auto-injected

Xcode's `productbuild` / build system injects `com.apple.application-identifier` and `com.apple.developer.team-identifier` into the embedded entitlements automatically. Raw `codesign` does not. Without them `cloudd` rejects all CloudKit calls:

```
cloudd: Invalid value of (null) for entitlement com.apple.application-identifier
```

The substituted entitlements plist must include them explicitly:

```xml
<key>com.apple.application-identifier</key>
<string>9VM4RM39R3.com.caterm.app</string>
<key>com.apple.developer.team-identifier</key>
<string>9VM4RM39R3</string>
```

`9VM4RM39R3` is the team id; replace with your own (the OU= from Pitfall 2).

## Pitfall 7 — `$(TeamIdentifierPrefix)` placeholder isn't substituted by `codesign`

`Resources/Caterm.entitlements` ships with `$(TeamIdentifierPrefix)caterm.shared` for `keychain-access-groups`. Xcode substitutes this at build time. Raw `codesign` does not — it embeds the literal string and AMFI rejects it.

Workflow: copy the entitlements file to `/tmp/Caterm-substituted.entitlements`, replace `$(TeamIdentifierPrefix)` with `9VM4RM39R3.` (note the trailing dot — `TeamIdentifierPrefix` includes it), add the `application-identifier` / `team-identifier` / `icloud-container-environment` keys from Pitfalls 6 + 4, then sign with `--entitlements /tmp/Caterm-substituted.entitlements`.

## Embedding the profile

The provisioning profile must live inside the bundle as `Contents/embedded.provisionprofile` **before** the outer codesign runs:

```bash
cp ~/Downloads/Caterm_Mac_Dev_Apple_Dev.provisionprofile \
   .build/release/Caterm.app/Contents/embedded.provisionprofile
```

`codesign` reads it during signing to confirm the cert/device/entitlements all match the profile.

## Sanity-check the signature

```bash
codesign -d --entitlements - .build/release/Caterm.app 2>&1 \
  | grep -E "(icloud|application-identifier|team-identifier)"
```

You should see all three keys with the team-prefixed values. If any are missing, re-sign with the right `--entitlements` plist.

## When AMFI rejects the launch

```bash
log stream --predicate 'subsystem == "com.apple.amfi"' --info --debug
```

Run it in one terminal, launch the app in another. AMFI logs the exact mismatch (cert SHA1 mismatch, device id not in profile, profile not yet effective, etc.) — much more useful than the generic `Killed: 9` you see in the launching shell.

For unredacted error messages (the default log shows `<private>`), prepend `sudo`:

```bash
sudo log show --last 2m --predicate 'process == "amfid"' --info --debug
```

`unsatisfiedEntitlements: ["foo"]` in the output names the exact entitlement key whose value the binary asserts but the profile does not permit — usually the fastest path to root cause.

## Pitfall 8 — APS entitlement key is `com.apple.developer.aps-environment` on macOS

The iOS form is the bare `aps-environment`. On macOS, AMFI matches against the **`com.apple.developer.aps-environment`** key (with `com.apple.developer.` prefix) — same form the profile uses. Putting `aps-environment` on the binary while the profile lists `com.apple.developer.aps-environment` produces:

```
amfid: unsatisfiedEntitlements: [aps-environment]
amfid: Error -413 "No matching profile found"
```

— even with the correct embedded profile, app id, cert, and device. Confirmed by inspecting Apple's own apps (Safari, Keynote, Xcode) — they all use the prefixed form.

## Pitfall 9 — Multiple Apple Development certs with the same Common Name

Apple's auto-renewal flow can leave two or three certs in your login keychain that share the CN `Apple Development: <Name> (XXXXXXXXXX)` but differ in SHA-1 fingerprint. `security find-identity -v -p codesigning` shows them all as valid; `codesign --sign "CN..."` fails with `ambiguous`.

The signed cert must match the cert whose SHA-1 is embedded in the profile's `DeveloperCertificates` array. To find which one:

```bash
python3 - <<'PY' < <(security cms -D -i ~/Downloads/Caterm_Mac_Dev_Apple_Dev.provisionprofile)
import plistlib, sys, hashlib
p = plistlib.loads(sys.stdin.buffer.read())
for c in p.get('DeveloperCertificates') or []:
    print(hashlib.sha1(c).hexdigest().upper())
PY
```

Then pass that SHA-1 directly to codesign — it accepts a fingerprint as a `--sign` argument and resolves unambiguously:

```bash
CATERM_DEV_IDENTITY=28A2AF9F761AB261B3144E4AF67373EC0F883ED1 make sign
```

`Scripts/dev-codesign.sh` detects a 40-hex `CATERM_DEV_IDENTITY` and looks up the team OU via the matching cert.

## CloudKit silent push (Plan B Phase 0)

- **Date:** 2026-05-02
- **Result:** PASS
- **Latency observed:** ~30s from CloudKit Dashboard write to `didReceiveRemoteNotification`
- **Chain validated end-to-end:**
  - `didRegisterForRemoteNotifications token-bytes=32` (APS reachable, device token issued)
  - `CKDatabaseSubscription` saved on `iCloud.com.caterm.app` private DB
  - Same-device `CKRecord` write succeeded but did NOT push back (CloudKit by-design suppresses notifications to the originating device — confirmed via spike)
  - Cross-origin write (Dashboard) successfully delivered the silent push within ~30s
- **Notes:** spike code (auto-spike runner in `AppDelegate` + `CloudKitPushSpikeView`) reverted in Task 0.3. Phase 2 push-subscription wiring can rely on the verified pipeline.

## Dev workflow recap (Plan B Phase 0)

After the entitlement edit + Apple Developer Portal work, the actual local sequence:

```bash
# Find the cert SHA-1 listed in your downloaded profile
PROFILE_CERT_SHA1=$(python3 -c "
import plistlib, sys, hashlib, subprocess
p = plistlib.loads(subprocess.check_output(['security','cms','-D','-i',sys.argv[1]]))
print(hashlib.sha1((p['DeveloperCertificates'] or [b''])[0]).hexdigest().upper())
" ~/Downloads/Caterm_Mac_Dev_Apple_Dev.provisionprofile)

# Build, sign, wrap in .app, embed profile, launch
CATERM_DEV_IDENTITY="$PROFILE_CERT_SHA1" make run-app
```

`Scripts/dev-run-app.sh` defaults `CATERM_DEV_PROFILE=~/Downloads/Caterm_Mac_Dev_Apple_Dev.provisionprofile`; override with `CATERM_DEV_PROFILE=...` if you keep the profile elsewhere.

## Distribution recipe (Plan E Phase 3)

The dev pipeline (`make run-app`) signs against `aps-environment=development` and Development CloudKit env. Shipping requires the **Production** counterparts:

| | Dev | Distribution |
|---|---|---|
| Cert | Apple Development | Developer ID Application **or** Mac App Distribution |
| Profile | Mac App Development | Distribution profile (App ID with `aps-environment=production` + `icloud-container-environment=Production` enabled in the App ID config) |
| `aps-environment` (in entitlements) | `development` | `production` |
| `com.apple.developer.icloud-container-environment` | absent (CloudKit defaults to Development with a Mac App Development profile) | `Production` |
| Build config | debug | release |
| Entitlements file | `Resources/Caterm.entitlements` | `Resources/Caterm.distribution.entitlements` |
| Driver | `make run-app` | `make dist` |

### `make dist`

```bash
CATERM_DIST_IDENTITY=<SHA-1 or CN of Distribution cert> \
CATERM_DIST_PROFILE_PATH=~/Downloads/Caterm_Mac_Dist.provisionprofile \
make dist
```

Internally:
1. `swift build -c release` — release-config binaries land at `.build/release/{caterm,caterm-askpass}`.
2. `Scripts/dev-codesign.sh --profile distribution` — substitutes `$(TeamIdentifierPrefix)` in `Resources/Caterm.distribution.entitlements`, signs each inner binary with `--options runtime`, persists the substituted entitlements alongside the binaries (`.build/release/Caterm.distribution.entitlements` and `.build/release/CatermAskpass.distribution.entitlements`).
3. `Scripts/dist-package.sh` — assembles the `.app` shell, embeds the Distribution profile, then re-seals in **two passes**:
   - Pass 1: re-sign `Contents/MacOS/caterm-askpass` with `CatermAskpass.distribution.entitlements`.
   - Pass 2: outer-bundle seal with `Caterm.distribution.entitlements` (Pitfall 5 — outer codesign without `--entitlements` clears the inner main exe's entitlements).
4. Three-way `codesign -d --entitlements -` verification on bundle + main + askpass; the script aborts on any failed assertion.

The script does NOT call `open` — Distribution builds are for the test Macs, not local launch.

### Askpass entitlement isolation

`caterm-askpass` is `exec`'d as a plain nested binary by `/usr/bin/ssh`. AMFI **SIGKILLs** it before `main()` if it carries restricted app/team identity entitlements (`application-identifier`, `team-identifier`, `aps-environment`, `icloud-container-environment`, etc.).

`keychain-access-groups` is restricted the same way: AMFI only honours it when an embedded provisioning profile authorises it, and a bare Mach-O helper (unlike the `.app` bundle) cannot embed one. A Distribution helper carrying `keychain-access-groups` is therefore SIGKILLed at `exec` exactly like the identity keys above — `ssh` then gets no password and the connection fails with `Permission denied (publickey,password)`.

`dev-codesign.sh` strips `keychain-access-groups` (and all app/team identity keys) from **both** binaries in **both** profiles; the helper reaches the keychain via the login-keychain default group + partition list. The runtime never sets `kSecAttrAccessGroup` (`CATERM_TEAM_ID` is unset, so `SessionStore` passes `accessGroup=nil`), so the named shared group is unused regardless. `dist-package.sh` then asserts the helper has **none** of `keychain-access-groups`, `application-identifier`, `team-identifier`, `aps-environment`, or `icloud-container-environment`; failure aborts the pipeline.

### Single-string `icloud-container-environment` form

`Resources/Caterm.distribution.entitlements` uses:

```xml
<key>com.apple.developer.icloud-container-environment</key>
<string>Production</string>
```

Do **not** wrap the value in `<array><string>Production</string></array>`. The array form appears in some provisioning-profile contexts (the profile carries an array because it permits multiple environments), but the **binary's own entitlements** must use the single-string form — otherwise the `cloudd` daemon mismatches the entitlement and downgrades to Development at runtime, leaving you with records flowing into the wrong container with no error message.

### Verifying signatures

After `make dist`, the script's three-way assertions cover the static side:

```bash
codesign -d --entitlements - .build/release/Caterm.app
codesign -d --entitlements - .build/release/Caterm.app/Contents/MacOS/caterm
codesign -d --entitlements - .build/release/Caterm.app/Contents/MacOS/caterm-askpass
```

Expected:

- **Bundle + main**: `<string>production</string>` for APS, `<string>Production</string>` for CloudKit env, `keychain-access-groups` present.
- **Askpass**: `keychain-access-groups` present; `aps-environment`, `icloud-container-environment`, `application-identifier`, `com.apple.developer.team-identifier` all **absent**.

For the runtime side, launch the app and filter `Console.app` on subsystem `com.caterm.app`, category `signing-diag`. AppDelegate logs one line at launch:

```
Resolved entitlements: aps=production ck-env=Production
```

If `ck-env=<unset>` shows up against a Distribution build, the binary will silently hit the Development container and the two-Mac smoke will fail in confusing ways — re-run `make dist` and re-verify before continuing.

### Notarization (Developer ID path only)

For Mac App Distribution (App Store) you upload the `.app` to App Store Connect via Transporter / `xcrun altool`. For Developer ID (direct distribution outside the App Store) you must notarize:

```bash
xcrun notarytool submit --keychain-profile <profile-name> \
    --wait .build/release/Caterm.app
xcrun stapler staple .build/release/Caterm.app
```

`make dist` does NOT run notarization — that requires interactive Apple credentials and is left to the human packaging the release.

## Sparkle auto-update

### One-time key setup

`generate_keys` was run once to produce an EdDSA key pair for signing
update packages. The **private key is stored in the login Keychain** and
is never committed. The **public key is committed at
`Scripts/sparkle_public_key.txt`**; `dist-package.sh` reads it and injects
it into the app's `Info.plist` as `SUPublicEDKey` at build time.

**Losing the private key permanently breaks future auto-updates** — users
already running a Sparkle-enabled build will see a signature-verification
failure and refuse to install any new release. Back it up: a gitignored
export exists at `sign/sparkle_ed_private_key.txt`; copy that into a
password manager as well.

### First Sparkle-enabled release

Builds installed before Sparkle existed have no updater baked in — they
cannot receive the first Sparkle release automatically. Distribute that
release manually (announce the `.dmg`). Auto-update works for all
subsequent releases once users are running a Sparkle-enabled build.

### Release flow

`make publish` generates `appcast.xml` via `generate_appcast` from a
staging directory and uploads it alongside the `.dmg` and `.app.zip` to
the GitHub release. The feed URL baked into every build is:

```
https://github.com/ZingerLittleBee/Caterm/releases/latest/download/appcast.xml
```

The release version and `CFBundleVersion` are derived automatically from
the top `## [X.Y.Z]` entry in `CHANGELOG.md` (skipping `## [Unreleased]`)
by `Scripts/lib-version.sh` — no `CATERM_DIST_VERSION` env var is needed.

`--draft` releases are not supported for the published feed: GitHub's
`/releases/latest` redirect ignores drafts, so the appcast would never
be served. Do not pass `ARGS=--draft` for a real Sparkle release.
