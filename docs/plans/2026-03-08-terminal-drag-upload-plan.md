# Terminal Drag & Drop File Upload — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow users to drag files/folders from the OS onto the terminal to upload them to the remote server's current working directory via SFTP.

**Architecture:** OSC 7 shell integration tracks the terminal CWD. Tauri's `onDragDropEvent` captures OS file drops with full paths. Auto-created SFTP sessions handle uploads. A floating progress bar at the terminal bottom shows transfer status. A directory picker dialog serves as fallback when CWD is unknown.

**Tech Stack:** xterm.js (OSC 7 parser), Tauri v2 webview API (drag-drop events), existing SFTP upload infrastructure, React components.

---

### Task 1: Add CWD Tracking to SSH Session State

**Files:**
- Modify: `apps/web/src/types/ssh.ts:14-19`
- Modify: `apps/web/src/components/ssh/ssh-session-provider.tsx`

**Step 1: Add `cwd` field to `SshSessionInfo`**

In `apps/web/src/types/ssh.ts`, add optional `cwd` to the interface:

```typescript
export interface SshSessionInfo {
  hostId: string
  hostName: string
  id: string
  status: SshSessionStatus
  cwd?: string
}
```

**Step 2: Add `updateCwd` to the session provider**

In `apps/web/src/components/ssh/ssh-session-provider.tsx`:

Add `updateCwd` to the context interface:

```typescript
interface SshSessionContextValue {
  activeSessionId: string | null
  connect: (params: ConnectParams) => Promise<string>
  disconnect: (sessionId: string) => Promise<void>
  retry: (sessionId: string) => Promise<void>
  sessions: Map<string, SshSessionInfo>
  setActive: (sessionId: string | null) => void
  updateCwd: (sessionId: string, cwd: string) => void
}
```

Add the implementation inside `SshSessionProvider`:

```typescript
const updateCwd = useCallback((sessionId: string, cwd: string) => {
  setSessions((prev) => {
    const session = prev.get(sessionId)
    if (!session) {
      return prev
    }
    const next = new Map(prev)
    next.set(sessionId, { ...session, cwd })
    return next
  })
}, [])
```

Add `updateCwd` to the provider value object.

**Step 3: Verify**

Run: `bun run check-types`

**Step 4: Commit**

```bash
git add apps/web/src/types/ssh.ts apps/web/src/components/ssh/ssh-session-provider.tsx
git commit -m "feat: add CWD tracking to SSH session state"
```

---

### Task 2: Register OSC 7 Handler in SshTerminal

**Files:**
- Modify: `apps/web/src/components/ssh/ssh-terminal.tsx`

**Step 1: Add `onCwdChange` prop**

```typescript
interface SshTerminalProps {
  hostId: string
  isActive: boolean
  onCwdChange?: (cwd: string) => void
  onRetry?: () => void
  sessionId: string
  status: SshSessionStatus
}
```

Store in a ref (same pattern as `onRetry`):

```typescript
const onCwdChangeRef = useRef(onCwdChange)
onCwdChangeRef.current = onCwdChange
```

**Step 2: Register OSC 7 handler in the terminal initialization effect**

After `terminal.open(container)` and before the WebGL addon, add:

```typescript
// Track current working directory via OSC 7 escape sequences.
// Shells emit: \x1b]7;file://hostname/path\x07
const osc7Disposable = terminal.parser.registerOscHandler(7, (data) => {
  try {
    const url = new URL(data)
    if (url.protocol === 'file:') {
      const cwd = decodeURIComponent(url.pathname)
      onCwdChangeRef.current?.(cwd)
    }
  } catch {
    // Malformed URI — ignore
  }
  return false
})
```

Add `osc7Disposable.dispose()` to the cleanup function alongside the other disposals.

**Step 3: Verify**

Run: `bun run check-types`

**Step 4: Commit**

```bash
git add apps/web/src/components/ssh/ssh-terminal.tsx
git commit -m "feat: register OSC 7 handler for CWD tracking in terminal"
```

---

### Task 3: Wire CWD Updates in SshIndexPage

**Files:**
- Modify: `apps/web/src/routes/ssh/index.tsx:253-262`

**Step 1: Import and use `updateCwd`**

Destructure `updateCwd` from `useSshSessions()`:

```typescript
const { sessions, activeSessionId, connect, disconnect, retry, setActive, updateCwd } = useSshSessions()
```

**Step 2: Pass `onCwdChange` to each `SshTerminal`**

Update the terminal rendering:

```typescript
<SshTerminal
  hostId={session.hostId}
  isActive={session.id === activeSessionId}
  key={session.id}
  onCwdChange={(cwd) => updateCwd(session.id, cwd)}
  onRetry={() => retry(session.id)}
  sessionId={session.id}
  status={session.status}
/>
```

**Step 3: Verify**

Run: `bun run check-types`

**Step 4: Commit**

```bash
git add apps/web/src/routes/ssh/index.tsx
git commit -m "feat: wire CWD tracking from terminal to session provider"
```

---

### Task 4: Create Terminal Drag Overlay Component

**Files:**
- Create: `apps/web/src/components/ssh/terminal-drop-overlay.tsx`

**Step 1: Create the overlay component**

```typescript
import { Upload } from 'lucide-react'

interface TerminalDropOverlayProps {
  visible: boolean
}

export function TerminalDropOverlay({ visible }: TerminalDropOverlayProps) {
  if (!visible) {
    return null
  }

  return (
    <div className="pointer-events-none absolute inset-0 z-50 flex items-center justify-center bg-background/60 backdrop-blur-sm">
      <div className="flex flex-col items-center gap-3 rounded-xl border-2 border-dashed border-primary bg-background/80 px-12 py-8">
        <Upload className="h-10 w-10 text-primary" />
        <p className="font-medium text-lg text-primary">Release to upload files</p>
      </div>
    </div>
  )
}
```

**Step 2: Verify**

Run: `bun run check-types`

**Step 3: Commit**

```bash
git add apps/web/src/components/ssh/terminal-drop-overlay.tsx
git commit -m "feat: add terminal drag overlay component"
```

---

### Task 5: Create Terminal Upload Progress Component

**Files:**
- Create: `apps/web/src/components/ssh/terminal-upload-progress.tsx`

**Step 1: Create the floating progress component**

Reuse patterns from `sftp-transfer-queue.tsx` (formatBytes, ProgressBar, status badge):

```typescript
import { ArrowUpFromLine, ChevronDown, ChevronUp, X } from 'lucide-react'
import { useEffect, useState } from 'react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import type { TransferStatus, TransferTaskInfo } from '@/types/sftp'

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`
}

function statusVariant(status: TransferStatus): 'default' | 'destructive' | 'outline' | 'secondary' {
  switch (status) {
    case 'completed':
      return 'default'
    case 'failed':
      return 'destructive'
    case 'active':
      return 'secondary'
    default:
      return 'outline'
  }
}

interface TerminalUploadProgressProps {
  onCancel: (transferId: string) => void
  transfers: TransferTaskInfo[]
}

export function TerminalUploadProgress({ transfers, onCancel }: TerminalUploadProgressProps) {
  const [collapsed, setCollapsed] = useState(false)
  const [visible, setVisible] = useState(true)

  // Auto-hide after all transfers complete
  useEffect(() => {
    const allDone = transfers.length > 0 && transfers.every((t) => t.status === 'completed' || t.status === 'failed')
    if (!allDone) {
      setVisible(true)
      return
    }
    const timer = setTimeout(() => setVisible(false), 3000)
    return () => clearTimeout(timer)
  }, [transfers])

  if (transfers.length === 0 || !visible) {
    return null
  }

  const activeCount = transfers.filter((t) => t.status === 'active' || t.status === 'pending').length

  return (
    <div className="absolute right-2 bottom-2 left-2 z-40 overflow-hidden rounded-lg border bg-background/95 shadow-lg backdrop-blur-sm">
      <button
        className="flex w-full items-center justify-between px-3 py-1.5 text-sm hover:bg-muted"
        onClick={() => setCollapsed((prev) => !prev)}
        type="button"
      >
        <span className="font-medium">
          Uploading{activeCount > 0 ? ` (${activeCount} active)` : ''} — {transfers.length} file{transfers.length > 1 ? 's' : ''}
        </span>
        {collapsed ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
      </button>
      {!collapsed && (
        <div className="max-h-40 overflow-y-auto">
          {transfers.map((task) => {
            const fileName = task.localPath.split('/').pop() ?? task.localPath
            const percent = task.totalBytes && task.totalBytes > 0 ? Math.min((task.transferredBytes / task.totalBytes) * 100, 100) : 0
            const canCancel = task.status === 'active' || task.status === 'pending'

            return (
              <div className="flex items-center gap-3 border-t px-3 py-2" key={task.id}>
                <ArrowUpFromLine className="h-4 w-4 shrink-0 text-blue-500" />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <span className="truncate text-sm">{fileName}</span>
                    <Badge variant={statusVariant(task.status)}>{task.status}</Badge>
                  </div>
                  <div className="mt-1 flex items-center gap-2">
                    <div className="h-2 min-w-0 flex-1 overflow-hidden rounded-full bg-muted">
                      <div className="h-full rounded-full bg-primary transition-all" style={{ width: `${percent}%` }} />
                    </div>
                    <span className="shrink-0 text-muted-foreground text-xs">
                      {formatBytes(task.transferredBytes)}
                      {task.totalBytes !== null ? ` / ${formatBytes(task.totalBytes)}` : ''}
                    </span>
                  </div>
                </div>
                {canCancel && (
                  <Button onClick={() => onCancel(task.id)} size="icon" variant="ghost">
                    <X className="h-3.5 w-3.5" />
                    <span className="sr-only">Cancel</span>
                  </Button>
                )}
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
```

**Step 2: Verify**

Run: `bun run check-types`

**Step 3: Commit**

```bash
git add apps/web/src/components/ssh/terminal-upload-progress.tsx
git commit -m "feat: add floating upload progress component for terminal"
```

---

### Task 6: Create Remote Directory Picker Dialog

**Files:**
- Create: `apps/web/src/components/ssh/remote-directory-picker.tsx`

This dialog is the fallback when OSC 7 CWD is not available. It lets the user browse remote directories via SFTP and select a target.

**Step 1: Create the directory picker dialog**

Use the same Dialog pattern as other dialogs in the project (`@base-ui/react/dialog`). Use SFTP `listDir` to navigate.

```typescript
import { Dialog } from '@base-ui-components/react/dialog'
import { ChevronRight, Folder, FolderOpen } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { Button } from '@/components/ui/button'
import type { FileEntry } from '@/types/fs'

interface RemoteDirectoryPickerProps {
  listDir: (path: string) => Promise<FileEntry[]>
  onCancel: () => void
  onSelect: (path: string) => void
  open: boolean
}

export function RemoteDirectoryPicker({ open, onSelect, onCancel, listDir }: RemoteDirectoryPickerProps) {
  const [currentPath, setCurrentPath] = useState('/')
  const [entries, setEntries] = useState<FileEntry[]>([])
  const [loading, setLoading] = useState(false)

  const loadDir = useCallback(
    async (path: string) => {
      setLoading(true)
      try {
        const items = await listDir(path)
        setEntries(items.filter((e) => e.isDir).sort((a, b) => a.name.localeCompare(b.name)))
        setCurrentPath(path)
      } catch {
        // Failed to list directory
      } finally {
        setLoading(false)
      }
    },
    [listDir]
  )

  useEffect(() => {
    if (open) {
      loadDir('/')
    }
  }, [open, loadDir])

  const handleNavigate = (entry: FileEntry) => {
    loadDir(entry.path)
  }

  const handleGoUp = () => {
    if (currentPath === '/') return
    const parent = currentPath.replace(/\/[^/]+\/?$/, '') || '/'
    loadDir(parent)
  }

  const pathSegments = currentPath.split('/').filter(Boolean)

  return (
    <Dialog.Root onOpenChange={(isOpen) => !isOpen && onCancel()} open={open}>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-50 bg-black/40" />
        <Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-md -translate-x-1/2 -translate-y-1/2 rounded-lg border bg-background p-0 shadow-lg">
          <Dialog.Title className="border-b px-4 py-3 font-semibold text-lg">
            Select upload directory
          </Dialog.Title>

          {/* Breadcrumb */}
          <div className="flex items-center gap-1 border-b px-4 py-2 text-sm">
            <button className="text-muted-foreground hover:text-foreground" onClick={() => loadDir('/')} type="button">/</button>
            {pathSegments.map((seg, i) => {
              const segPath = `/${pathSegments.slice(0, i + 1).join('/')}`
              return (
                <span className="flex items-center gap-1" key={segPath}>
                  <ChevronRight className="h-3 w-3 text-muted-foreground" />
                  <button className="text-muted-foreground hover:text-foreground" onClick={() => loadDir(segPath)} type="button">{seg}</button>
                </span>
              )
            })}
          </div>

          {/* Directory list */}
          <div className="h-64 overflow-y-auto">
            {currentPath !== '/' && (
              <button
                className="flex w-full items-center gap-2 px-4 py-2 text-sm hover:bg-muted"
                onClick={handleGoUp}
                type="button"
              >
                <Folder className="h-4 w-4 text-muted-foreground" />
                ..
              </button>
            )}
            {loading ? (
              <div className="flex h-full items-center justify-center text-muted-foreground text-sm">Loading...</div>
            ) : (
              entries.map((entry) => (
                <button
                  className="flex w-full items-center gap-2 px-4 py-2 text-sm hover:bg-muted"
                  key={entry.path}
                  onClick={() => handleNavigate(entry)}
                  type="button"
                >
                  <FolderOpen className="h-4 w-4 text-muted-foreground" />
                  {entry.name}
                </button>
              ))
            )}
          </div>

          {/* Actions */}
          <div className="flex items-center justify-between border-t px-4 py-3">
            <span className="truncate text-muted-foreground text-sm">{currentPath}</span>
            <div className="flex gap-2">
              <Dialog.Close>
                <Button onClick={onCancel} size="sm" variant="outline">Cancel</Button>
              </Dialog.Close>
              <Button onClick={() => onSelect(currentPath)} size="sm">Select</Button>
            </div>
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
```

**Step 2: Verify**

Run: `bun run check-types`

**Step 3: Commit**

```bash
git add apps/web/src/components/ssh/remote-directory-picker.tsx
git commit -m "feat: add remote directory picker dialog for upload fallback"
```

---

### Task 7: Create Terminal Drag Upload Hook

**Files:**
- Create: `apps/web/src/components/ssh/use-terminal-drag-upload.ts`

This hook encapsulates Tauri drag-drop event listening and file upload orchestration.

**Step 1: Create the hook**

```typescript
import { invoke } from '@tauri-apps/api/core'
import { getCurrentWebview } from '@tauri-apps/api/webview'
import { useCallback, useEffect, useRef, useState } from 'react'
import { toast } from 'sonner'
import type { FileEntry } from '@/types/fs'
import type { TransferTaskInfo } from '@/types/sftp'
import type { SshSessionInfo } from '@/types/ssh'

interface UseTerminalDragUploadParams {
  /** Ref to the terminal area container element */
  terminalAreaRef: React.RefObject<HTMLDivElement | null>
  /** Current active SSH session */
  activeSession: SshSessionInfo | null
  /** Function to get/create SFTP session for a host, returns SFTP session ID */
  ensureSftpSession: (hostId: string) => Promise<string>
  /** SFTP upload function */
  upload: (sftpSessionId: string, localPath: string, remotePath: string) => Promise<string>
  /** SFTP mkdir function */
  mkdir: (sftpSessionId: string, path: string) => Promise<void>
  /** SFTP listDir function */
  listDir: (sftpSessionId: string, path: string) => Promise<FileEntry[]>
  /** Called when CWD is unavailable and user must pick a directory */
  onNeedDirectoryPick: () => void
}

interface UseTerminalDragUploadResult {
  /** Whether files are being dragged over the terminal */
  isDragOver: boolean
}

export function useTerminalDragUpload({
  terminalAreaRef,
  activeSession,
  ensureSftpSession,
  upload,
  mkdir,
  listDir,
  onNeedDirectoryPick,
}: UseTerminalDragUploadParams): UseTerminalDragUploadResult {
  const [isDragOver, setIsDragOver] = useState(false)

  // Store latest values in refs to avoid re-subscribing to Tauri events
  const activeSessionRef = useRef(activeSession)
  activeSessionRef.current = activeSession
  const ensureSftpSessionRef = useRef(ensureSftpSession)
  ensureSftpSessionRef.current = ensureSftpSession
  const uploadRef = useRef(upload)
  uploadRef.current = upload
  const mkdirRef = useRef(mkdir)
  mkdirRef.current = mkdir
  const listDirRef = useRef(listDir)
  listDirRef.current = listDir
  const onNeedDirectoryPickRef = useRef(onNeedDirectoryPick)
  onNeedDirectoryPickRef.current = onNeedDirectoryPick

  // Pending drop state for directory picker flow
  const pendingDropRef = useRef<{ paths: string[]; hostId: string } | null>(null)

  const isOverTerminal = useCallback(
    (x: number, y: number): boolean => {
      const el = terminalAreaRef.current
      if (!el) return false
      const rect = el.getBoundingClientRect()
      return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom
    },
    [terminalAreaRef]
  )

  const uploadPaths = useCallback(
    async (paths: string[], hostId: string, remoteCwd: string) => {
      let sftpSessionId: string
      try {
        sftpSessionId = await ensureSftpSessionRef.current(hostId)
      } catch (error) {
        const msg = error instanceof Error ? error.message : String(error)
        toast.error('Failed to create SFTP session', { description: msg })
        return
      }

      for (const localPath of paths) {
        try {
          const stat = await invoke<{ isDir: boolean }>('local_fs_stat', { path: localPath })
          if (stat.isDir) {
            await uploadDirectory(sftpSessionId, localPath, remoteCwd)
          } else {
            const fileName = localPath.split('/').pop() ?? localPath
            const remotePath = remoteCwd === '/' ? `/${fileName}` : `${remoteCwd}/${fileName}`
            await uploadRef.current(sftpSessionId, localPath, remotePath)
          }
        } catch (error) {
          const msg = error instanceof Error ? error.message : String(error)
          toast.error(`Failed to upload ${localPath.split('/').pop()}`, { description: msg })
        }
      }
    },
    []
  )

  /** Handle the result from the directory picker */
  const handleDirectoryPicked = useCallback(
    (remotePath: string) => {
      const pending = pendingDropRef.current
      if (!pending) return
      pendingDropRef.current = null
      uploadPaths(pending.paths, pending.hostId, remotePath)
    },
    [uploadPaths]
  )

  useEffect(() => {
    const webview = getCurrentWebview()
    let cancelled = false

    const setup = async () => {
      const unlisten = await webview.onDragDropEvent((event) => {
        if (cancelled) return

        if (event.payload.type === 'enter') {
          const { x, y } = event.payload.position
          if (isOverTerminal(x, y)) {
            setIsDragOver(true)
          }
        } else if (event.payload.type === 'over') {
          const { x, y } = event.payload.position
          setIsDragOver(isOverTerminal(x, y))
        } else if (event.payload.type === 'drop') {
          setIsDragOver(false)
          const { paths, position } = event.payload
          if (!isOverTerminal(position.x, position.y)) return
          if (!paths || paths.length === 0) return

          const session = activeSessionRef.current
          if (!session || session.status !== 'connected') {
            toast.error('No active SSH session')
            return
          }

          if (session.cwd) {
            uploadPaths(paths, session.hostId, session.cwd)
          } else {
            // No CWD available — ask user to pick a directory
            pendingDropRef.current = { paths, hostId: session.hostId }
            onNeedDirectoryPickRef.current()
          }
        } else if (event.payload.type === 'leave') {
          setIsDragOver(false)
        }
      })

      if (cancelled) {
        unlisten()
        return
      }

      // Store unlisten for cleanup
      cleanupRef.current = unlisten
    }

    const cleanupRef = { current: () => {} }
    setup()

    return () => {
      cancelled = true
      cleanupRef.current()
    }
  }, [isOverTerminal, uploadPaths])

  return { isDragOver, handleDirectoryPicked }
}

/** Recursively upload a local directory to remote via SFTP */
async function uploadDirectory(
  sftpSessionId: string,
  localDirPath: string,
  remoteParentPath: string
): Promise<void> {
  const dirName = localDirPath.split('/').pop() ?? localDirPath
  const remoteDirPath = remoteParentPath === '/' ? `/${dirName}` : `${remoteParentPath}/${dirName}`

  // Create remote directory (ignore error if exists)
  try {
    await invoke('sftp_mkdir', { sessionId: sftpSessionId, path: remoteDirPath })
  } catch {
    // Directory may already exist
  }

  // List local directory contents
  const entries = await invoke<Array<{ name: string; path: string; isDir: boolean }>>('local_fs_list_dir', {
    path: localDirPath
  })

  for (const entry of entries) {
    if (entry.isDir) {
      await uploadDirectory(sftpSessionId, entry.path, remoteDirPath)
    } else {
      const remotePath = `${remoteDirPath}/${entry.name}`
      await invoke('sftp_upload', {
        sessionId: sftpSessionId,
        localPath: entry.path,
        remotePath
      })
    }
  }
}
```

**Note:** The return type needs adjustment — `handleDirectoryPicked` must be exposed. Update the result interface:

```typescript
interface UseTerminalDragUploadResult {
  isDragOver: boolean
  handleDirectoryPicked: (remotePath: string) => void
}
```

**Step 2: Verify**

Run: `bun run check-types`

**Step 3: Commit**

```bash
git add apps/web/src/components/ssh/use-terminal-drag-upload.ts
git commit -m "feat: add terminal drag upload hook with Tauri drag-drop events"
```

---

### Task 8: Integrate Everything in SshIndexPage

**Files:**
- Modify: `apps/web/src/routes/ssh/index.tsx`

**Step 1: Add imports**

```typescript
import { useRef, useState } from 'react'
import { TerminalDropOverlay } from '@/components/ssh/terminal-drop-overlay'
import { TerminalUploadProgress } from '@/components/ssh/terminal-upload-progress'
import { RemoteDirectoryPicker } from '@/components/ssh/remote-directory-picker'
import { useTerminalDragUpload } from '@/components/ssh/use-terminal-drag-upload'
```

**Step 2: Add `ensureSftpSession` helper**

This function gets or creates an SFTP session for a given host. Add inside `SshIndexPage`:

```typescript
const terminalAreaRef = useRef<HTMLDivElement>(null)
const [dirPickerOpen, setDirPickerOpen] = useState(false)
const [dirPickerSftpId, setDirPickerSftpId] = useState<string | null>(null)

// Map hostId → sftpSessionId for drag-upload sessions
const uploadSftpMapRef = useRef<Map<string, string>>(new Map())

const ensureSftpSession = useCallback(
  async (hostId: string): Promise<string> => {
    // Check if we already have a session
    const existing = uploadSftpMapRef.current.get(hostId)
    if (existing) {
      // Verify session still exists in provider
      const sessions = sftpSessions
      if (sessions.has(existing)) {
        return existing
      }
      uploadSftpMapRef.current.delete(hostId)
    }

    // Create new SFTP session
    const stored = await client.sshHost.getById({ id: hostId })
    const id = await openStandalone({
      authType: stored.authType as 'password' | 'key',
      hostId: stored.id,
      hostName: stored.name,
      hostname: stored.hostname,
      keyPassphrase: stored.keyPassphrase ?? undefined,
      password: stored.password ?? undefined,
      port: stored.port,
      privateKey: stored.privateKey ?? undefined,
      username: stored.username
    })
    uploadSftpMapRef.current.set(hostId, id)
    return id
  },
  [openStandalone]
)
```

Also destructure `sessions: sftpSessions` from `useSftp()` (rename to avoid conflict):

```typescript
const { openStandalone, upload, mkdir, listDir, cancelTransfer, transfers, sessions: sftpSessions } = useSftp()
```

**Step 3: Use the drag upload hook**

```typescript
const { isDragOver, handleDirectoryPicked } = useTerminalDragUpload({
  terminalAreaRef,
  activeSession,
  ensureSftpSession,
  upload,
  mkdir,
  listDir,
  onNeedDirectoryPick: () => {
    // Need to ensure SFTP session for dir picker
    if (activeSession) {
      ensureSftpSession(activeSession.hostId).then((id) => {
        setDirPickerSftpId(id)
        setDirPickerOpen(true)
      })
    }
  }
})
```

**Step 4: Filter transfers for current terminal's uploads**

```typescript
const terminalUploads = transfers.filter((t) => {
  if (t.kind !== 'upload') return false
  if (!activeSession) return false
  const sftpId = uploadSftpMapRef.current.get(activeSession.hostId)
  return t.sftpSessionId === sftpId
})
```

**Step 5: Update the terminal area JSX**

Add `ref` to the terminal container div, overlay, and progress bar:

```tsx
{/* Terminal + optional file tree panel */}
<div className="relative flex min-h-0 flex-1">
  <div className="relative min-w-0 flex-1" ref={terminalAreaRef}>
    {sessions.size === 0 ? (
      <div className="flex h-full items-center justify-center text-muted-foreground">
        <p>Select a host to connect or add a new one.</p>
      </div>
    ) : (
      Array.from(sessions.values()).map((session) => (
        <SshTerminal
          hostId={session.hostId}
          isActive={session.id === activeSessionId}
          key={session.id}
          onCwdChange={(cwd) => updateCwd(session.id, cwd)}
          onRetry={() => retry(session.id)}
          sessionId={session.id}
          status={session.status}
        />
      ))
    )}
    <TerminalDropOverlay visible={isDragOver} />
    <TerminalUploadProgress onCancel={cancelTransfer} transfers={terminalUploads} />
  </div>

  {sftpPanelOpen && sftpSessionId && (
    <div className="w-64 shrink-0">
      <SftpSidebarTree sftpSessionId={sftpSessionId} />
    </div>
  )}
</div>
```

**Step 6: Add directory picker dialog**

Before the closing `</SidebarProvider>`, add:

```tsx
<RemoteDirectoryPicker
  listDir={
    dirPickerSftpId
      ? (path) => listDir(dirPickerSftpId, path)
      : async () => []
  }
  onCancel={() => setDirPickerOpen(false)}
  onSelect={(path) => {
    setDirPickerOpen(false)
    handleDirectoryPicked(path)
  }}
  open={dirPickerOpen}
/>
```

**Step 7: Verify**

Run: `bun run check-types`

**Step 8: Verify formatting**

Run: `bun x ultracite fix`

**Step 9: Commit**

```bash
git add apps/web/src/routes/ssh/index.tsx
git commit -m "feat: integrate drag-and-drop file upload in terminal page"
```

---

### Task 9: Manual Testing & Polish

**Step 1: Start the development environment**

Run: `bun run dev:server` and `bun run tauri:dev` (or `make dev`)

**Step 2: Test OSC 7 CWD tracking**

- Connect to an SSH session
- If the remote shell supports OSC 7 (bash/zsh with appropriate config), change directories and verify the CWD is tracked
- Check that the session info shows the current directory

**Step 3: Test file drag-and-drop**

- Drag a single file from Finder onto the terminal
- Verify the overlay appears during drag
- Verify the file uploads to the CWD (or directory picker opens if no CWD)
- Check the floating progress bar shows progress and auto-dismisses

**Step 4: Test folder drag**

- Drag a folder from Finder onto the terminal
- Verify recursive upload creates the directory structure

**Step 5: Test fallback directory picker**

- Connect to a server without OSC 7 shell integration
- Drag a file onto the terminal
- Verify the directory picker opens
- Navigate and select a target directory
- Verify the upload goes to the selected directory

**Step 6: Final commit**

Fix any issues found during testing and commit.

```bash
git add -A
git commit -m "fix: polish terminal drag upload after manual testing"
```
