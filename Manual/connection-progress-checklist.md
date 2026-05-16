# Connection Progress UI — Manual Verification

Run after any change to `SessionStore.startConnection`, `Preflight`,
`ConnectingOverlay`, `FailureOverlay`, or `TerminalContainerView`.

Build + launch:

```
cd apps/macos && make run-app
```

For each scenario below, observe the overlay state, then either let it
resolve or click Retry / Edit Host as instructed.

## 1. Happy path — fast LAN host
- Add a host on your LAN that you can reach instantly.
- Connect.
- **Expect:** brief flash of `Connecting…` (< 500ms), then `Authenticating…`,
  then overlay fades out within ~150ms. No `elapsed` line should show.

## 2. Slow connect — VPN or remote host
- Connect to a host across a VPN or another continent.
- **Expect:** `Connecting…` shown ≥ 1s; once elapsed ≥ 2s, the
  `elapsed Ns` line appears. Stage transitions to `Authenticating…` once
  TCP completes. Overlay fades out on success.

## 3. DNS failure
- Add a host with hostname `caterm-no-such-host-xyz.invalid` port 22.
- Connect.
- **Expect:** within ~5s, overlay turns to FailureOverlay:
  - Orange `!` icon
  - Title "Host not found"
  - Detail "Could not resolve hostname caterm-no-such-host-xyz.invalid"
  - Retry / Edit Host buttons.

## 4. Connection refused
- Add a host with `hostname=127.0.0.1`, `port=2`. Connect.
- **Expect:** overlay shows "Connection refused" within ~1s,
  detail "Port 2 is not accepting connections".

## 5. Connection timed out
- Add a host with `hostname=192.0.2.1` (TEST-NET-1), `port=22`. Connect.
- **Expect:** overlay shows "Connection timed out" after ~5s, detail
  references `192.0.2.1:22`. (TEST-NET-1 is reserved for examples and
  black-holes packets.)

## 6. Authentication failure
- Add a real reachable host but provide a wrong password / key.
- Connect.
- **Expect:** overlay transitions through `Connecting…` → `Authenticating…`,
  ssh subprocess exits, FailureOverlay shows "Authentication failed",
  red `!` icon, Retry / Edit Host buttons.

## 7. Retry button
- After any failure overlay appears, click Retry.
- **Expect:** overlay returns to `Connecting…` and the flow re-runs.

## 8. Edit Host button
- After a failure overlay, click Edit Host.
- **Expect:** the existing host edit sheet opens with the failed host
  pre-populated. Cancel returns to the failure overlay.

## 9. Invalid port (legacy data)
- Manually edit `~/Library/Application Support/Caterm/.../hosts.json`
  to set a host's `port` to `99999`. Restart the app.
- Connect to that host.
- **Expect:** overlay immediately shows "Invalid port" (red icon), detail
  "Port 99999 is out of range (1–65535) — edit host to fix".

## 10. Reconnect path unchanged
- Connect successfully. Disconnect the network mid-session.
- **Expect:** existing `ReconnectOverlay` (with countdown) still renders.
  Once the timer fires, the new flow activates: `Connecting…` overlay
  appears (preflight). If still offline, "No network" failure shown.
- Reconnect the network; let auto-reconnect succeed.

## 11. Concurrent retries don't race
- Trigger a failure, click Retry rapidly multiple times within 1s.
- **Expect:** only the latest attempt's outcome lands in the overlay.
  No flicker between "auth-success" surfaces from stale attempts.
