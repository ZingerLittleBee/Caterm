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

## Failure modes

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Exit 137 from caterm-askpass | binary signed with `keychain-access-groups` but no provisioning profile | use login-keychain path (do not set `CATERM_ACCESS_GROUP`) until provisioning profile is wired |
| Keychain dialog popup | first-time access by a freshly resigned binary | click "Always Allow" once; subsequent runs are silent |
| `spawn askpass: Permission denied` | binary not executable | `chmod +x .build/debug/caterm-askpass` |
| `Permission denied (password,publickey)` | secret not in keychain | run KeychainStore set via Task 1.7 UI; or re-add via signed test harness |
| Exit code 3 with osStatus -25243 | access group entitlement mismatch | re-check Resources/CatermAskpass.entitlements |
| Exit code 3 with osStatus -25291 | login keychain locked | unlock via Keychain Access |
