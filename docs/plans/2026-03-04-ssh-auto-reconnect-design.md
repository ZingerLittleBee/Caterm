# SSH Auto-Reconnect Design

## Goal

Implement backend-driven automatic reconnection for SSH sessions on unexpected disconnects, preserving terminal scrollback history and buffering user input during reconnection for a seamless experience.

## Approach: Backend-Driven Reconnect (Option B)

Reconnect logic lives in the Rust backend (`session.rs` reader loop). The frontend receives status events and displays inline terminal feedback. This minimizes IPC round-trips, keeps the same `sessionId`, and allows input buffering during brief outages.

## Disconnect Classification

| Signal | Type | Behavior |
|--------|------|----------|
| `ChannelCommand::Close` | User-initiated | No reconnect, exit loop |
| `ChannelMsg::Eof` + `Close` | Server normal close | No reconnect |
| Channel returns `None` (TCP drop) | Unexpected | Trigger reconnect |

## Backend Architecture

### ReconnectConfig

`SshSession` stores connection parameters at creation time:

```rust
struct ReconnectConfig {
    hostname: String,
    port: u16,
    username: String,
    auth: AuthMethod, // Password(String) | PrivateKey { key, passphrase }
}
```

Credentials live in memory for the session's lifetime and are released when the session is removed from `SshSessionManager`.

### Reconnect Loop (inside reader task)

1. Detect `channel.wait()` returning `None`
2. Emit `ssh-reconnecting-{id}` event (`{ attempt, max_attempts, next_delay_ms }`)
3. Create new `russh` connection using saved `ReconnectConfig`
4. Authenticate, open channel, request PTY (using last known terminal size), request shell
5. On success: emit `ssh-reconnected-{id}`, flush input buffer, resume reader loop with new channel
6. On failure: wait `delay`, increment attempt, go to step 2
7. After max attempts: emit `ssh-disconnect-{id}` with `{ reason: "failed" }`, exit loop

### Backoff Parameters

- Initial delay: 1s
- Multiplier: 2x
- Max delay cap: 30s
- Max attempts: 5

### Input Buffering

During reconnection:
- `ChannelCommand::Data` messages are appended to a `Vec<Vec<u8>>` buffer instead of failing
- `ChannelCommand::Resize` stores the latest value (only last resize matters)
- On successful reconnect, buffered data is flushed in order, then resize is applied

## Events

| Event | When | Payload |
|-------|------|---------|
| `ssh-reconnecting-{id}` | Each reconnect attempt starts | `{ attempt: u32, max_attempts: u32, next_delay_ms: u64 }` |
| `ssh-reconnected-{id}` | Reconnect succeeds | `{}` |
| `ssh-disconnect-{id}` | Final failure or user close | `{ reason: "user" \| "failed" }` |

## Frontend Changes

### Session Status

Add `"reconnecting"` to `SshSessionStatus`:

```typescript
type SshSessionStatus = "connecting" | "connected" | "reconnecting" | "disconnected" | "error";
```

### Terminal Inline Feedback

Write ANSI-colored text directly into the xterm terminal:

- Reconnecting: `\x1b[33mConnection lost. Reconnecting (1/5)...\x1b[0m`
- Success: `\x1b[32mReconnected.\x1b[0m`
- Final failure: `\x1b[31mReconnection failed after 5 attempts.\x1b[0m\r\n\x1b[31mPress Enter to retry or close this tab.\x1b[0m`

### Tab Bar / Status Bar

- `"reconnecting"` status shows yellow blinking indicator + "Reconnecting" label
- Existing `"disconnected"` and `"connected"` indicators unchanged

### Input During Reconnect

- Terminal remains interactive (not disabled, no overlay)
- User keystrokes are sent to backend via normal `ssh_write` path
- Backend buffers them and flushes on reconnect success

### Manual Retry

After all automatic attempts fail:
- User presses Enter in terminal
- Frontend detects this and calls `invoke("ssh_retry", { sessionId })`
- Backend restarts the reconnect loop from attempt 1

## Files to Modify

### Rust Backend
- `src-tauri/src/ssh/session.rs` — ReconnectConfig, reconnect loop, input buffer, event emission
- `src-tauri/src/ssh/manager.rs` — Add `retry()` method
- `src-tauri/src/commands/ssh_commands.rs` — Add `ssh_retry` command, pass credentials to ReconnectConfig

### Frontend
- `types/ssh.ts` — Add `"reconnecting"` status
- `components/ssh/ssh-session-provider.tsx` — Listen for reconnecting/reconnected events, update status
- `components/ssh/ssh-terminal.tsx` — Write inline reconnect messages, handle manual retry on Enter
- `components/ssh/ssh-tab-bar.tsx` — Yellow indicator for reconnecting
- `components/ssh/ssh-status-bar.tsx` — Reconnecting label/color
