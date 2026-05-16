# Host Chaining — Manual Verification

Run after any change to `SSHHost` data model, `SSHCommandBuilder`,
`CatermAskpass`/`CatermAskpassCore`, `SessionStore`, the host form,
the sidebar, or any of the connection overlays.

Build + launch:

```
cd apps/macos && make run-app
```

## 1. Single hop — keyFile + agent (happy path)
- Configure host A with key auth and connect once to seed credentials.
- Configure host B; in the **Via host** picker, select A. The caption
  should read `Will connect via A`. Save.
- Connect B.
- **Expect:** `ConnectingOverlay` shows `via u@A.example.com` below
  the host line. Connection succeeds.

## 2. Single hop — password jump
- Configure A with password auth; connect once to seed the password.
- Configure B with `Via host = A`.
- Connect B.
- **Expect:** Connection succeeds. `caterm-askpass.log` (in
  `~/Library/Logs/Caterm/`) contains a line with
  `mode=chain account=<A-uuid>.password`.

## 3. Single hop — key+passphrase jump (also exercises Task 1 prereq fix)
- Configure A with `keyFile` + passphrase; connect once to seed.
- Configure B with `Via host = A`.
- Connect B.
- **Expect:** Connection succeeds. Log line shows
  `mode=chain account=<A-uuid>.keyPassphrase`.

## 4. Multi-hop — A → B → target
- Configure C with `Via host = B` (where B has `Via host = A`).
- Connect C.
- **Expect:** ConnectingOverlay shows `via u@A → u@B`. Connection
  succeeds.

## 5. Cycle prevention at edit time
- Edit B and try to set `Via host = B`. The picker excludes B
  (self-reference rule).
- Edit A and try to set `Via host = B`. The picker excludes B
  because B's chain references A (cycle prevention).

## 6. Broken chain after deletion
- Configure B → A. Verify connection works.
- Delete A. The fan-out alert appears: "A is used by 1 host as their
  jump host. Delete anyway?". Confirm.
- Open B's edit form. The chain caption reads
  `Will connect via (deleted)` in red. Save is disabled.
- Try to connect B. The tab opens directly to a `FailureOverlay`
  reading "Jump host chain is broken — edit host to fix" without
  ever spawning ssh.

## 7. Missing credential on jump
- Configure A but skip the credential setup (or revoke it via the
  sidebar's credential reset). Configure B → A.
- Try to connect B.
- **Expect:** Tab opens directly to FailureOverlay reading
  `A needs credentials configured first — connect to it directly to
  set them up`. ssh is never spawned.

## 8. Sidebar chain icon
- Hosts with `jumpHostServerId` set show the
  `arrow.triangle.branch` icon next to the name.
- Hovering surfaces a tooltip with the full chain text
  (`via A → B`).

## 9. CloudKit sync to a second device
- On device 1, configure B → A and let sync settle.
- On device 2 (same iCloud account), wait for the next sync. B's
  edit form should show `Via host = A` correctly.
- Note: credentials do NOT sync (Keychain is local). Re-enter A's
  credential on device 2 before connecting B.

## 10. Server-sync (custom backend) round-trip
- Edit B → A on device 1; trigger a push.
- On a fresh-install device 2 logged into the same Caterm account,
  pull. B's `jumpHostServerId` should match A's `serverId`.

## 11. ssh_config injection rejection
- Edit a host and try to set the hostname to `bastion\nProxyCommand /tmp/evil`
  (paste a literal newline). Save.
- **Expect:** Save is rejected with a validation error, OR the save
  succeeds at the form level but the eventual connect fails-fast
  with "ssh_config encoding error" rather than executing the
  injected ProxyCommand.
- Verify with `ls -la ~/Library/Caches/Caterm/ssh-configs/` that no
  config containing the injected ProxyCommand was written.

## 12. Cleanup of per-session ssh_config files
- Connect a chain. Note files in
  `~/Library/Caches/Caterm/ssh-configs/`. Close the tab.
- **Expect:** the corresponding `.conf` file is deleted within
  seconds of tab close.
