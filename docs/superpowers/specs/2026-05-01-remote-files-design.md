# Remote Files (SFTP + Drag Upload) — Design Spec

**Status:** Draft (awaiting user review)
**Date:** 2026-05-01
**Scope:** macOS app (`apps/macos/`) only. Web app already has parity.

---

## 1. Goal

Add a remote file browser and drag-drop upload to the macOS Caterm app, so users can list / transfer / delete / rename / mkdir on the remote host without leaving the terminal tab.

This brings macOS to feature parity with the web app on file operations, while staying consistent with the existing macOS architecture (system `ssh(1)` subprocess + askpass helper).

## 2. Architecture

### 2.1 Backend: system `sftp(1)` subprocess + ControlMaster

- Reuse the existing OpenSSH binary on the system (no new deps).
- Each connected host gets a long-lived **ControlMaster socket** at `~/Library/Caches/Caterm/cm/<hostId>.sock`.
  - The first `ssh` (terminal) connection opens it (`-o ControlMaster=auto -o ControlPersist=10m -o ControlPath=…`).
  - Subsequent `sftp` invocations reuse the socket — no re-authentication, no MFA prompts.
- Credential flow continues through the existing `caterm-askpass` helper (only invoked on the first session that establishes the master).
- We always **force-override** the user's `~/.ssh/config` ControlMaster settings via explicit `-o ControlPath=...` flags, so the socket location is deterministic.
- ControlMaster sockets are cleaned up on app quit (via existing SessionStore lifecycle hook).

### 2.2 Foreground: SwiftUI/AppKit drawer in MainWindow

- A right-side **NSSplitView** drawer (`FileDrawerView`) attached to the existing terminal area.
- Toggle: toolbar `📁` button + keyboard `⌘⇧F`.
- Default state: **collapsed**.
- Per-host last-visited path is remembered (in `settings.plist` or a sibling file); fallback to `~`.

### 2.3 Module layout

```
Sources/
├─ SFTPCommandBuilder/                        ← NEW target (parallel to SSHCommandBuilder)
│   ├─ SFTPCommandBuilder.swift               (build sftp subprocess argv)
│   ├─ SFTPBatchScript.swift                  (build sftp batch-mode scripts: ls/get/put/...)
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

## 3. Data Flow

```
User action (click row / drag in / press ⌘⇧F)
   ↓
RemoteFileSystem.{list, get, put, mkdir, rm, rename}
   ↓ (constructs argv via SFTPCommandBuilder)
sftp -o ControlPath=<sock> user@host
   ↓ (batch script via stdin)
sftp executes commands → stdout/stderr
   ↓ (parsed line-by-line)
Update FileTransferStore (progress per file)
   ↓
SwiftUI bindings → drawer UI refresh
```

### 3.1 Why batch mode

`sftp` supports `-b <file>` (batch script) and stdin scripting. Each `RemoteFileSystem` operation runs `sftp` in batch mode with a per-operation script:

- `list("/etc")` → `cd /etc\nls -la\n`
- `upload(local, remote)` → `put -P <local> <remote>`  (`-P` preserves perms)
- `download(remote, local)` → `get -P <remote> <local>`
- `mkdir(path)` → `mkdir <path>` (after `cd parent`)
- `rm(path)` → `rm <path>` or `rmdir <path>`
- `rename(from, to)` → `rename <from> <to>`
- `copyPath(path)` → no sftp call; just resolves and copies absolute path to NSPasteboard

Batch mode exits with non-zero on any failure → easy error handling.

### 3.2 Progress (file-level, not byte-level)

`sftp` emits a line per completed file in batch mode (and `-v` for verbose). We parse these lines to advance the queue. Byte-level progress within a single file is **not** in v1 (acceptable trade-off documented in Q1 of brainstorm).

## 4. Components

### 4.1 `SFTPCommandBuilder` (new target)

Mirrors `SSHCommandBuilder` patterns. Key API:

```swift
public struct SFTPInvocation {
    public let argv: [String]               // process arguments
    public let environment: [String: String]
    public let scriptStdin: String          // batch script
}

public enum SFTPCommandBuilder {
    public static func invocation(
        host: Host,
        controlPath: URL,
        operation: SFTPOperation
    ) -> SFTPInvocation
}

public enum SFTPOperation {
    case list(remotePath: String)
    case put(localPath: URL, remotePath: String)
    case get(remotePath: String, localPath: URL)
    case mkdir(remotePath: String)
    case remove(remotePath: String, isDirectory: Bool)
    case rename(from: String, to: String)
}
```

### 4.2 `SSHCommandBuilder` modifications

Append ControlMaster options to all `ssh` invocations:

```
-o ControlMaster=auto
-o ControlPersist=10m
-o ControlPath=<host-cache-dir>/<hostId>.sock
```

Cache dir: `~/Library/Caches/Caterm/cm/`. Caterm creates the directory at startup (mode 0700).

### 4.3 `FileTransferStore` (new target, `@MainActor` `ObservableObject`)

```swift
@MainActor
public final class FileTransferStore: ObservableObject {
    @Published public private(set) var tasks: [TransferTask] = []
    public func enqueueUpload(localFiles: [URL], remoteDir: String, hostId: HostId) -> [TaskId]
    public func enqueueDownload(remotePaths: [String], localDir: URL, hostId: HostId) -> [TaskId]
    public func cancel(_ taskId: TaskId)
    public func cancelAll()
    public func retry(_ taskId: TaskId)
}

public struct TransferTask {
    public let id: TaskId
    public let kind: Kind                    // upload | download
    public let hostId: HostId
    public let source: String
    public let destination: String
    public var status: Status                // pending | running | completed | failed | cancelled
    public var error: String?
}
```

Single FIFO queue per host (avoids overwriting same path in parallel).

### 4.4 `RemoteFileSystem` (new, in `FileTransferStore` target)

Stateless wrapper that constructs and runs `SFTPCommandBuilder` invocations. Returns `async` results.

```swift
public actor RemoteFileSystem {
    public init(hostId: HostId, controlPath: URL)
    public func list(_ path: String) async throws -> [RemoteEntry]
    public func mkdir(_ path: String) async throws
    public func remove(_ path: String, isDirectory: Bool) async throws
    public func rename(from: String, to: String) async throws
    // upload/download go through FileTransferStore for progress
}

public struct RemoteEntry {
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let mtime: Date
    public let mode: UInt16                  // unix permissions
}
```

### 4.5 `FileDrawerView` (SwiftUI)

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
│   2/5 files · 40%           │
└─────────────────────────────┘
```

Right-click menu: Open enclosing folder · Download · Rename · Delete · Copy Path · New Folder.

### 4.6 Drag-drop integration

| Source → destination | Behavior |
|---|---|
| Finder file → drawer (any row) | upload to current drawer dir |
| Finder file → drawer row that is a directory | upload into that dir |
| Finder file → terminal (default) | paste shell-quoted path **(unchanged)** |
| Finder file → terminal + ⌥ held | upload to remote cwd (OSC 7); if no OSC 7 → modal sheet asks for target dir |
| Drawer row → Finder | download to drop location |

Implementation: `GhosttySurfaceNSView+Drag.swift` adds `⌥` modifier branch; `FileDrawerView` adds `NSDraggingDestination` to itself and rows; row→Finder uses `NSFilePromiseProvider` (download then hand off path).

### 4.7 Toolbar / Menu integration

- New `MainWindow` toolbar item: `📁` button (toggle drawer) + badge bubble showing active transfer count.
- Menu: **View → Show Files Drawer** ⌘⇧F.
- Menu: **File → Upload to Remote…** (only enabled when a tab is connected).

## 5. Error Handling

| Failure | Behavior |
|---|---|
| ssh control socket gone (user killed it / TTL) | sftp re-establishes a new master transparently; askpass may prompt |
| Permission denied (e.g. `put` to `/etc`) | Task → `failed`, error string surfaced in queue list, retry available |
| Disk full (local download) | Task → `failed`, error string surfaced |
| Network drop mid-transfer | sftp exits non-zero, task → `failed`, partial file marked with `.part` suffix on local side |
| Unknown SFTP error | Captured stderr → error string, task → `failed` |
| Drawer opened on disconnected tab | Show empty state with "Connect to browse files" prompt |

No automatic retry of failed transfers (user explicitly clicks retry). Avoids unintended re-upload loops.

## 6. Testing

### 6.1 Unit tests

- **`SFTPCommandBuilderTests`**
  - argv contains correct `-o ControlPath`
  - batch script for each operation matches expected format
  - shell-quoting for paths with spaces / quotes / unicode

- **`FileTransferStoreTests`**
  - FIFO ordering within a host
  - cancel mid-queue removes pending, kills running
  - retry resets a failed task
  - per-host concurrency = 1

- **`RemoteFileSystemTests`** (uses fake SFTP runner)
  - parses `ls -la` output into `RemoteEntry`
  - handles error exit codes

### 6.2 Manual smoke (`apps/macos/Manual/sftp-smoke.md`)

15 scenarios mirroring `end-to-end-smoke.md` style:
1. List home directory
2. Navigate via breadcrumb
3. Upload single file via drag-to-drawer
4. Upload directory tree
5. Download single file via drag-to-Finder
6. Drag file to terminal — pastes path (unchanged)
7. ⌥ + drag file to terminal — uploads to cwd
8. ⌥ + drag with no OSC 7 — modal sheet appears
9. Rename file, verify on remote
10. Delete file/directory
11. mkdir
12. Copy remote path → terminal paste verifies
13. Cancel mid-upload — partial file cleaned up
14. Network blip — failed task shown, retry succeeds
15. Disconnect tab — drawer shows empty state

### 6.3 Integration smoke

Reuse the existing OpenSSH-in-Docker harness (already present per Spec analysis) to run end-to-end SFTP scenarios in CI.

## 7. Out of Scope (v2)

- chmod dialog
- Preview / edit (download to tmp + open + watch + re-upload)
- Bookmarks
- Search within current dir
- History back / forward
- Byte-level progress
- Multi-host parallel transfer queues
- Notifications on transfer completion
- Local file panel (Finder is good enough)

## 8. Open Questions

None at design time. All architectural decisions resolved in brainstorm.

## 9. References

- Existing `Sources/SSHCommandBuilder/SSHCommandBuilder.swift` — patterns to mirror
- Existing `Sources/Caterm/Views/MainWindow.swift` — split view integration point
- Existing `Sources/SessionStore/SessionStore.swift` — per-host lifecycle hooks for ControlMaster cleanup
- Web app reference: `apps/web/src/components/sftp/`, `apps/web/src/components/file-panel/`
- `apps/macos/Manual/end-to-end-smoke.md` — smoke test format precedent
