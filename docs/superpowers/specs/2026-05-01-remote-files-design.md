# Remote Files (SFTP + Drag Upload) — Design Spec

**Status:** Draft v3 (revised after second review 2026-05-01)
**Date:** 2026-05-01
**Scope:** macOS app (`apps/macos/`) only.

---

## 1. Goal

Add a remote file browser and drag-drop upload to the macOS Caterm app, so users can list / transfer / delete / rename / mkdir on the remote host without leaving the terminal tab.

This brings macOS to feature parity with the web app on file operations, while staying consistent with the existing macOS architecture (system `ssh(1)` subprocess + askpass helper).

## 2. Architecture

### 2.1 Backend: system `sftp(1)` subprocess + ControlMaster reuse

- Reuse the existing OpenSSH binary (no new deps).
- Each connected host gets a long-lived **ControlMaster socket** at `~/Library/Caches/Caterm/cm/<hostId>.sock`.
  - The first `ssh` (terminal) connection opens it (`-o ControlMaster=auto -o ControlPersist=10m -o ControlPath=…`).
  - Subsequent `sftp` invocations reuse the socket — no re-authentication, no MFA prompts.
- Credential flow continues through the existing `caterm-askpass` helper (only invoked on the first session that establishes the master).
- We always **force-override** the user's `~/.ssh/config` ControlMaster settings via explicit `-o ControlPath=...` flags on every invocation, so the socket location is deterministic.
- ControlMaster sockets are cleaned up on app quit (via existing SessionStore lifecycle hook).

### 2.2 Connection-state contract (no transparent re-auth)

If the ControlMaster is not actively serving (TTL expired, app restarted, ssh subprocess crashed, OS killed it) we **do not** silently re-authenticate from `sftp`. The drawer is a passive consumer of an already-authenticated session.

**Liveness check is required, not just file existence.** OpenSSH's ssh client falls back to a normal connection when ControlPath points at a missing or non-listening socket — meaning a stale `.sock` file plus a sftp invocation would re-auth. `BatchMode=yes` alone is **insufficient**: it only blocks interactive prompts; SSH agent (`SSH_AUTH_SOCK`), passphrase-less keys, and any `kbd-interactive` method that doesn't prompt would still authenticate non-interactively and successfully establish a new connection without the user noticing. We block this with three layered defenses:

1. **Liveness check** — `ssh -S <socket> -O check <user@host>` before each `sftp` invocation. Per `ssh(1)`, `-O check` "check that the master process is running"; non-zero exit → master is gone. The `<user@host>` destination argument is **mandatory** (otherwise ssh prints a usage error). The same destination string used for the original session is reused.
2. **No-fallback options on every `sftp` invocation** (passed via `-o`):
   - `ControlMaster=no` — forbid creating a *new* master from this sftp call (which would silently re-auth)
   - `BatchMode=yes` — disable interactive prompts (defense in depth)
   - `PreferredAuthentications=none` — refuse all auth methods, including agent and key auth
   - `ProxyCommand=none` — defeat any user-config `ProxyCommand` that could re-establish connectivity through other means
3. **Credentials surface still passed** (§3.4) to enforce identical host-key and known-hosts policy as the original ssh, even on the (unreachable in practice) failure path.

With these three layers, if the master is missing or dies between the check and sftp's actual connect, sftp **cannot**:
- attach to a missing socket (ControlMaster=no forbids creating a new one to fall back to),
- authenticate via agent or key (PreferredAuthentications=none lists no methods),
- prompt the user (BatchMode=yes),
- proxy through another path (ProxyCommand=none).

→ sftp exits non-zero, UI shows banner "Reconnect host to browse files" with an action button that triggers the existing reconnect FSM in `SessionStore`.

This resolves the apparent contradiction with §3.4: credentials are supplied for **policy parity** (host key checking, known-hosts file paths, identity files for the *master* connection), not for re-authentication. Re-auth from sftp is structurally impossible.

**Test coverage to lock the contract** (in `RemoteFileSystemTests`):
- `testNoFallbackWhenAgentLoaded`: with `SSH_AUTH_SOCK` pointing at a working agent and the master socket deleted, list operation throws `.sessionGone` and never produces a sftp subprocess that connects.
- `testNoFallbackWhenPasswordlessKeyAvailable`: with `~/.ssh/id_ed25519` (no passphrase) granting access to the test host and the master socket deleted, list throws `.sessionGone`.
- `testInvocationFlagsPresent`: `SFTPInvocation.argv` contains all four `-o` no-fallback options.

### 2.3 Foreground: SwiftUI/AppKit drawer in MainWindow

- A right-side **NSSplitView** drawer (`FileDrawerView`) attached to the existing terminal area.
- Toggle: toolbar `📁` button + keyboard `⌘⇧F`.
- Default state: **collapsed**.
- Per-host last-visited path is remembered (in a sibling JSON file `file-drawer-state.json` next to `hosts.json`); fallback to `~`.

### 2.4 Module layout

```
Sources/
├─ SFTPCommandBuilder/                        ← NEW target (parallel to SSHCommandBuilder)
│   ├─ SFTPCommandBuilder.swift               (build sftp subprocess argv)
│   ├─ SFTPPathEncoder.swift                  (validate + escape paths for sftp batch)
│   └─ ControlPath.swift                      (compute deterministic socket paths)
├─ SSHCommandBuilder/
│   └─ SSHCommandBuilder.swift                ← MODIFIED: add ControlMaster opts
├─ FileTransferStore/                         ← NEW target
│   ├─ FileTransferStore.swift                (queue, progress, cancel)
│   ├─ TransferTask.swift
│   └─ RemoteFileSystem.swift                 (list/mkdir/rm/rename/get/put — wraps SFTPCommandBuilder)
└─ Caterm/Views/
    ├─ FileDrawerView.swift                   ← NEW
    ├─ RemoteFileListView.swift               ← NEW
    ├─ TransferQueueView.swift                ← NEW
    └─ MainWindow.swift                       ← MODIFIED: split view + toolbar button
```

## 3. Backend execution model

### 3.1 One sftp subprocess per operation (file-level granularity)

Per reviewer's analysis, `sftp -b` is quiet by default and the progress meter is interactive-only with no stable line protocol. Instead:

- **Each file transfer = one `sftp(1)` subprocess.** Queue advances when the subprocess exits. Exit code 0 → success; non-zero → failure.
- **Each browse op = one `sftp(1)` subprocess** that runs a tiny batch script (e.g., `ls -la`).
- **Directory transfers** use `put -R` / `get -R` in a single subprocess; counted as 1 unit in the queue (the user sees "Uploading: <dirname>"). No mid-directory progress (acceptable v1 trade-off).

This trades a small per-file process spawn cost (~50ms over ControlMaster) for:
- Simple, robust progress tracking (subprocess exited = item done)
- Clean cancellation (kill the subprocess; partial file already on remote stays unless we explicitly cleanup)
- Easy retry (just rerun the same subprocess; `put -a` resumes if same path)

### 3.2 SFTP batch script construction

Each subprocess is invoked with `sftp -b /dev/stdin <host>` and the script piped via stdin. Examples:

| Operation | Subprocess argv (key parts) | Stdin script |
|---|---|---|
| `list("/etc")` | `sftp -b /dev/stdin -o ControlPath=… <host>` | `cd "/etc"\nls -la\nexit\n` |
| `upload(local, "/srv/app/")` | `sftp -b /dev/stdin -o ControlPath=… <host>` | `put -p "/local/file" "/srv/app/file"\nexit\n` |
| `uploadDir(local, "/srv/app/")` | same | `put -pR "/local/dir" "/srv/app/dir"\nexit\n` |
| `download` | same | `get -p "/remote/file" "/local/file"\nexit\n` |
| `mkdir("/srv/new")` | same | `mkdir "/srv/new"\nexit\n` |
| `rm("/srv/file")` | same | `rm "/srv/file"\nexit\n` |
| `rmdir("/srv/empty")` | same | `rmdir "/srv/empty"\nexit\n` |
| `rename(a, b)` | same | `rename "/a" "/b"\nexit\n` |

Note: **lowercase `-p`** preserves permissions and access times in interactive `put`/`get` (per `man sftp` line 410, 339). Uppercase `-P` is the top-level CLI port flag — different feature.

`-a` (resume) is **not** used by default; only on explicit user retry of a failed task. `-R` is used when the source path is a directory.

### 3.3 SFTP path encoding (`SFTPPathEncoder`)

`sftp` batch scripts are NOT shell. The parser (`misc.c::makeargv` in OpenSSH) does its own quoting/escaping. We must use SFTP-specific rules, not shell rules.

**`SFTPPathEncoder` API:**

```swift
public enum SFTPPathEncoder {
    /// Returns a quoted form safe to embed in a batch script line.
    /// Throws if the path contains a byte that cannot be safely transmitted
    /// (newline, NUL, other control chars). Caller surfaces error to UI.
    public static func encode(_ path: String) throws -> String
}

public enum SFTPPathEncodingError: Error {
    case empty                                  // empty string after trim
    case containsControlChar(Character)         // \n, \0, \r, \t, etc.
    case containsGlob(Character)                // *, ?, [
    case lineTooLong(bytes: Int)                // exceeds SFTP_MAX_LSARGS (1023)
    case leadingDashUnnormalized                // path starts with '-' and caller did not normalize
}
```

**Encoding rules (matching OpenSSH sftp's makeargv parser):**

1. **Reject** paths containing any byte in `0x00..=0x1F` or `0x7F` (control chars including NL, CR, TAB, NUL). Raise `containsControlChar`. SFTP batch lines are newline-delimited, so embedded `\n` is unrepresentable.
2. **Always wrap** the path in double quotes: `"path"`.
3. **Inside quotes**, escape `"` and `\` with backslash: `"` → `\"`, `\` → `\\`.
4. **Leading dash**: paths starting with `-` would still be parsed as flags. Mitigation: prefix with `./` if the path is relative, or normalize absolute paths via `realpath`-style resolution before constructing the script.
5. **Glob characters** (`*`, `?`, `[`): sftp interactive interprets these. v1 **rejects** paths containing `*`, `?`, or `[` for safety, returning `containsGlob` (added to error enum). The drawer never feeds untrusted globs; user-typed paths get the same validation. (Enables future opt-in glob via a separate `glob:` API if needed.)
6. **Maximum line length**: 1023 bytes (OpenSSH `SFTP_MAX_LSARGS`); reject longer.

Test vectors (all in `SFTPPathEncoderTests`):
- `/etc/hosts` → `"/etc/hosts"`
- `/path/with space/file` → `"/path/with space/file"`
- `/path/"quoted"` → `"/path/\"quoted\""`
- `/path\with\back` → `"/path\\with\\back"`
- `-rf` → throws `leadingDashUnnormalized` (caller should normalize to `./-rf` before calling)
- `./-rf` → `"./-rf"` (accepted; leading character is `.`)
- `file\nname` → throws `containsControlChar('\n')`
- `*.txt` → throws `containsGlob('*')`
- `[abc].txt` → throws `containsGlob('[')`
- `""` → throws `empty`
- `/legit/path/that/is/very/long…` (1024+ bytes) → throws `lineTooLong(bytes:)`
- `/empty/` (path with trailing slash, non-empty) → `"/empty/"` (accepted)

### 3.4 SFTPInvocation API (revised — full auth surface)

```swift
public struct SFTPInvocation {
    public let argv: [String]                  // executable + arguments
    public let environment: [String: String]   // SSH_ASKPASS, DISPLAY, etc.
    public let scriptStdin: String             // batch script body
}

public struct SFTPCredentials {
    public let askpassPath: URL?               // path to caterm-askpass (policy parity only;
                                               //   never invoked under no-fallback options)
    public let identityFiles: [URL]            // -i flags (policy parity)
    public let knownHostsCaterm: URL           // first path joined into UserKnownHostsFile=
    public let knownHostsUser: URL             // second path; matches SSHCommandBuilder.swift:61
    public let strictHostKeyChecking: SSHCommandBuilder.StrictHostKeyChecking
    public let extraSSHOptions: [String: String]   // forward through -o (note: no-fallback
                                                   //   options are added by the builder, not
                                                   //   read from this map)
}

public enum SFTPCommandBuilder {
    /// Build a sftp invocation. `credentials` provides host-key and identity
    /// policy that mirrors SSHCommandBuilder so the resulting subprocess never
    /// applies a weaker policy than the active session — even though
    /// BatchMode=yes (set in argv) prevents any actual interactive auth.
    public static func invocation(
        host: Host,
        controlPath: URL,
        credentials: SFTPCredentials,
        operation: SFTPOperation
    ) throws -> SFTPInvocation
}

public enum SFTPOperation {
    case list(remoteDir: String)
    case put(localPath: URL, remotePath: String, recursive: Bool, resume: Bool)
    case get(remotePath: String, localPath: URL, recursive: Bool, resume: Bool)
    case mkdir(remotePath: String)
    case remove(remotePath: String, isDirectory: Bool)
    case rename(from: String, to: String)
}
```

`resume: Bool` controls the `-a` flag. v1 only sets `resume: true` when the user clicks Retry on a failed transfer (§4.2 `FileTransferStore.retry`). New transfers always start fresh.

Key change vs v1 spec: `credentials` parameter is **required**, but is used solely to set host-key, known-hosts, and identity-file policy (`-o UserKnownHostsFile=`, `-o StrictHostKeyChecking=`, `-i …`). `BatchMode=yes` in the argv guarantees no interactive auth ever happens, so credentials are policy-only, not auth-driving.

`SSHCommandBuilder` is refactored to expose a `credentials(for: Host)` factory so both builders share construction logic.

## 4. Components

### 4.1 `SSHCommandBuilder` modifications

Append ControlMaster options to all `ssh` invocations:

```
-o ControlMaster=auto
-o ControlPersist=10m
-o ControlPath=<host-cache-dir>/<hostId>.sock
```

Cache dir: `~/Library/Caches/Caterm/cm/`. Caterm creates the directory at startup with mode 0700.

Extract `credentials(for: Host)` factory used by both `SSHCommandBuilder` and `SFTPCommandBuilder`.

### 4.2 `FileTransferStore` (new target, `@MainActor` `ObservableObject`)

```swift
@MainActor
public final class FileTransferStore: ObservableObject {
    @Published public private(set) var tasks: [TransferTask] = []
    public func enqueueUpload(localPaths: [URL], remoteDir: String, hostId: HostId) -> [TaskId]
    public func enqueueDownload(remotePaths: [String], localDir: URL, hostId: HostId) -> [TaskId]
    public func cancel(_ taskId: TaskId)
    public func cancelAll(forHost: HostId? = nil)
    public func retry(_ taskId: TaskId)         // re-enqueues with -a (resume)
}

public struct TransferTask: Identifiable {
    public let id: TaskId
    public let kind: Kind                      // upload | download
    public let hostId: HostId
    public let source: String                  // for display
    public let destination: String             // for display
    public let isDirectory: Bool               // → -R flag
    public var status: Status                  // pending | running | completed | failed | cancelled
    public var error: String?                  // captured stderr on failure
}
```

Single FIFO queue **per host**. Multiple hosts can transfer in parallel. Within one host, items run strictly sequentially.

### 4.3 `RemoteFileSystem` (new, in `FileTransferStore` target)

```swift
public actor RemoteFileSystem {
    public init(hostId: HostId, controlPath: URL, credentials: SFTPCredentials)
    public func list(_ path: String) async throws -> [RemoteEntry]
    public func mkdir(_ path: String) async throws
    public func remove(_ path: String, isDirectory: Bool) async throws
    public func rename(from: String, to: String) async throws
    // upload/download go through FileTransferStore for queue + cancel
}

public struct RemoteEntry {
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let mtime: Date
    public let mode: UInt16                    // unix permissions
}
```

Internal flow per call:
1. **Liveness check** — run `ssh -S <controlPath> -O check <user@host>` (full destination required, see §2.2). If exit code ≠ 0, throw `.sessionGone` without invoking sftp.
2. Build `SFTPInvocation` via `SFTPCommandBuilder` (the four no-fallback `-o` options are unconditionally added by the builder).
3. Spawn `Process`; pipe stdin/stdout/stderr.
4. Write `scriptStdin`; close stdin.
5. Wait for exit.
6. On non-zero exit: capture last 1 KiB of stderr → throw `.subprocessFailed(exitCode, stderr)`.
7. On 0 exit: parse stdout (`ls -la` for list; nothing for transfer).

The previous "socket file exists" precondition is replaced by the active liveness check above — file existence does not prove the master is alive.

### 4.4 `FileDrawerView` (SwiftUI)

```
┌─────────────────────────────┐
│ /home/user/projects   ⟲ +  │   ← breadcrumb + refresh + mkdir
├─────────────────────────────┤
│ 📁 src                  4 KB│
│ 📁 docs                 2 KB│
│ 📄 README.md          12 KB │   ← list (right-click menu)
│ 📄 build.log         500 KB │
├─────────────────────────────┤
│ ⬆ uploading: photo.jpg  ×   │   ← sticky transfer area
│   2/5 files                  │
└─────────────────────────────┘
```

Right-click menu: Open enclosing folder · Download · Rename · Delete · Copy Path · New Folder.

Empty states:
- Disconnected tab: "Reconnect host to browse files" + reconnect button.
- Empty directory: standard SF Symbol + "Empty folder".
- Permission denied on cd: error inline with retry.

### 4.5 Drag-drop integration

| Source → destination | Behavior |
|---|---|
| Finder file → drawer (any row) | upload to current drawer dir |
| Finder file → drawer row that is a directory | upload into that dir |
| Finder file → terminal (default) | paste shell-quoted path **(unchanged)** |
| Finder file → terminal + ⌥ held | upload to remote cwd (OSC 7); if no OSC 7 → modal sheet asks for target dir |
| Drawer row → Finder | download to drop location |

Implementation: `GhosttySurfaceNSView+Drag.swift` adds `⌥` modifier branch; `FileDrawerView` adds `NSDraggingDestination` to itself and rows; row→Finder uses `NSFilePromiseProvider` (download then hand off path).

### 4.6 Toolbar / Menu integration

- New `MainWindow` toolbar item: `📁` button (toggle drawer) + badge bubble showing active transfer count.
- Menu: **View → Show Files Drawer** ⌘⇧F.
- Menu: **File → Upload to Remote…** (only enabled when a tab is connected).

## 5. Error Handling

| Failure | Behavior |
|---|---|
| ControlMaster socket missing | Drawer shows "Reconnect host to browse files" + reconnect button (per §2.2). No silent re-auth. |
| Permission denied (e.g. `put` to `/etc`) | Task → `failed`, error string surfaced in queue list, retry available |
| Disk full (local download) | Task → `failed`, error string surfaced |
| Network drop mid-transfer | sftp exits non-zero, task → `failed`, partial file remains on remote/local; retry uses `-a` (resume) |
| Path validation error (control char / glob / leading dash) | Operation rejected at API boundary with explicit error; no subprocess spawned |
| Unknown SFTP error | Captured stderr → error string, task → `failed` |
| Drawer opened on disconnected tab | Empty state with "Connect to browse files" prompt |

No automatic retry of failed transfers (user explicitly clicks retry). Avoids unintended re-upload loops.

## 6. Testing

### 6.1 Unit tests

- **`SFTPPathEncoderTests`**
  - All test vectors from §3.3
  - Round-trip property: every accepted path produces a quoted form that, when parsed by an SFTP-compatible argv parser, returns the original byte sequence

- **`SFTPCommandBuilderTests`**
  - argv contains correct `-o ControlPath`
  - batch script for each `SFTPOperation` matches expected format byte-for-byte
  - lowercase `-p` flag always; `-R` only when `recursive: true`; `-a` only when `resume: true` (set by `FileTransferStore.retry`)
  - credentials surface produces correct `-i`, `-o UserKnownHostsFile="<caterm-path> <user-path>"` (both paths joined with a space, matching SSHCommandBuilder.swift:61), `SSH_ASKPASS` env

- **`FileTransferStoreTests`**
  - FIFO ordering within a host
  - Two hosts run in parallel (separate FIFOs)
  - Cancel mid-queue removes pending, kills running
  - Retry resets a failed task and applies `-a`
  - Per-host concurrency = 1

- **`RemoteFileSystemTests`** (uses fake SFTP runner injected via protocol)
  - `.sessionGone` thrown when socket file is missing
  - parses `ls -la` output into `RemoteEntry`
  - handles error exit codes; surfaces stderr tail

### 6.2 Manual smoke (`apps/macos/Manual/sftp-smoke.md`)

15 scenarios mirroring `end-to-end-smoke.md` style:
1. List home directory
2. Navigate via breadcrumb
3. Upload single file via drag-to-drawer
4. Upload directory tree (verify `-R` flag effect)
5. Download single file via drag-to-Finder
6. Drag file to terminal — pastes path (unchanged)
7. ⌥ + drag file to terminal — uploads to cwd
8. ⌥ + drag with no OSC 7 — modal sheet appears
9. Rename file, verify on remote
10. Delete file/directory
11. mkdir
12. Copy remote path → terminal paste verifies
13. Cancel mid-upload — partial file remains; retry with `-a` resumes (verify with large file + tc throttle)
14. ControlMaster expires → drawer shows "Reconnect host" banner; reconnect button works
15. Path with spaces / quotes / unicode upload+download round-trip

### 6.3 Integration smoke

Reuse the existing OpenSSH-in-Docker harness to run end-to-end SFTP scenarios in CI: list, upload (file + directory), download, rename, delete, retry-resume.

## 7. Out of Scope (v2)

- chmod dialog
- Preview / edit (download to tmp + open + watch + re-upload)
- Bookmarks
- Search within current dir
- Glob support
- History back / forward
- Byte-level progress (would require a real SFTP client library, e.g. Citadel)
- Multi-host parallel transfer queues UI
- Notifications on transfer completion
- Local file panel (Finder is sufficient)

## 8. References

- Existing `Sources/SSHCommandBuilder/SSHCommandBuilder.swift` — patterns to mirror; will be refactored to extract shared credentials surface
- Existing `Sources/Caterm/Views/MainWindow.swift` — split view integration point
- Existing `Sources/SessionStore/SessionStore.swift` — per-host lifecycle hooks for ControlMaster cleanup; reconnect FSM driven from drawer empty state
- Web app reference: `apps/web/src/components/sftp/`, `apps/web/src/components/file-panel/`
- `apps/macos/Manual/end-to-end-smoke.md` — smoke test format precedent
- `man 1 sftp` (OpenSSH 9.x) — interactive `put`/`get` command syntax
- OpenSSH source `sftp.c::parse_args` and `misc.c::makeargv` — batch parser quoting rules
