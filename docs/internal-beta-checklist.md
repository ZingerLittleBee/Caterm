# Internal Beta Sync Verification Checklist

## Preconditions

- Machine A and machine B point to the same Caterm server and database.
- Both machines use the same `VITE_SERVER_URL`.
- Both machines start from a signed-out state.

## Machine A

1. Sign in.
2. Create one SSH host named `Beta Host A`.
3. Edit that host and change the port from `22` to `2222`.
4. Open `/ssh/settings`.
5. Change `Font Size` to `16`.
6. Change `Theme` to `solarized-dark` or any non-default theme.
7. Save settings.

## Machine B

1. Sign in with the same account.
2. Open `/ssh`.
3. Confirm `Beta Host A` appears in the host list.
4. Confirm the host shows port `2222`.
5. Connect to the host from the synced list.
6. Confirm the SSH terminal renders with the same global terminal settings.
7. Open `/ssh/settings`.
8. Confirm the saved font size and theme are present.

## Delete Propagation

1. Return to machine A.
2. Delete `Beta Host A`.
3. On machine B, retry host sync or reload `/ssh`.
4. Confirm `Beta Host A` disappears.

## Failure-State Checks

1. Disconnect the network or stop the server on machine B.
2. Reload `/ssh`.
3. Confirm session verification failure shows a blocking retry state, or host/settings failures show inline banners instead of false empty states.
4. Restore the network or server.
5. Retry and confirm synced data becomes available again.

## Known Beta Limitations

- SSH host key verification is not implemented yet; this beta is for trusted internal usage only.
- SSH host list has no local cache fallback. If host sync fails, the app must show an inline error instead of stale hosts.
- Terminal settings can briefly render cached values before reconciling to newer server state.
- SFTP transfer queue UI exists, but transfer scheduling and cancellation are not fully authoritative yet.
