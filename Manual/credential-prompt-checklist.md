# Credential Prompt — Manual Verification

Run after any change to `CredentialSetupView`, `HostFormView`, `AuthMethodFields`,
or `CredKind`.

Build + launch:

```
cd apps/macos && make run-app
```

## 1. Sheet height is stable across method flips
- On a fresh device or with a host whose local credential was deleted,
  click Connect on a host so the credential-prompt sheet appears.
- Click each method in turn: `Password` → `Key File` → `Agent` → `Password`.
- **Expect:** the sheet's outer frame does not move, resize, or reflow.
  The Cancel / Save buttons stay in the same position on the screen
  through every method change. Only the inner field area redraws.

## 2. Password method saves
- With the sheet open, choose `Password`. Enter a value. Click Save (or press ⏎).
- **Expect:** sheet dismisses, connection retries with the new credential.
  Re-opening the host (after wiping its credential again) shows a clean
  empty sheet — the previous secret is not pre-populated.

## 3. Key File method saves with no passphrase
- Choose `Key File`. Click `Browse…`, pick `~/.ssh/id_ed25519` (or any
  existing key). Leave `Key has passphrase` off. Click Save.
- **Expect:** sheet dismisses, connection retries.

## 4. Key File method with passphrase
- Choose `Key File`. Pick a key. Enable `Key has passphrase`. Type a
  value into the new `Passphrase` field. Click Save.
- **Expect:** sheet dismisses, connection retries. Save remains disabled
  until both the path and passphrase are non-empty.

## 5. Agent method saves
- Choose `Agent`. Click Save.
- **Expect:** sheet dismisses immediately (no secret input required).

## 6. Cancel button + ⎋
- Click Cancel. Then re-open the prompt and press the Escape key.
- **Expect:** both close the sheet without saving anything.

## 7. Error inline rendering
- Cause a save to fail (e.g., write a Keychain-blocked path or simulate
  via test hooks). Click Save.
- **Expect:** the sheet stays open and shows a red `errorMessage` line
  inside a third Section. The sheet's outer frame does not resize.

## 8. HostFormView (sister sheet) still works
- Open `Add Host` from the sidebar. Cycle through `Password` / `Key File`
  / `Agent` in the Authentication section.
- **Expect:** the form area below the picker swaps fields without
  shifting the Save button. Submit a new host and verify it appears
  in the sidebar.
