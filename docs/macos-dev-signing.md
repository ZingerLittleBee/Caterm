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
