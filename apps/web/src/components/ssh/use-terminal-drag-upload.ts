import { invoke } from '@tauri-apps/api/core'
import { getCurrentWebview } from '@tauri-apps/api/webview'
import { useCallback, useEffect, useRef, useState } from 'react'
import { toast } from 'sonner'
import type { FileEntry, FileStat } from '@/types/fs'

type UploadFn = (sftpSessionId: string, localPath: string, remotePath: string) => Promise<string>

interface UseTerminalDragUploadParams {
  /** Current active SSH session (with optional cwd) */
  activeSession: { hostId: string; status: string; cwd?: string } | null
  /** Function to get/create SFTP session for a host, returns SFTP session ID */
  ensureSftpSession: (hostId: string) => Promise<string>
  /** Called when CWD is unavailable and user must pick a directory */
  onNeedDirectoryPick: () => void
  /** Ref to the terminal area container element */
  terminalAreaRef: React.RefObject<HTMLDivElement | null>
  /** SFTP upload function: (sftpSessionId, localPath, remotePath) => transferId */
  upload: UploadFn
}

interface UseTerminalDragUploadResult {
  /** Call this when user picks directory from fallback picker */
  handleDirectoryPicked: (remotePath: string) => void
  /** Whether files are being dragged over the terminal */
  isDragOver: boolean
}

/** Build a remote path by joining parent and file name */
function joinRemotePath(parent: string, name: string): string {
  return parent === '/' ? `/${name}` : `${parent}/${name}`
}

/** Upload a single local path (file or directory) to the remote */
async function uploadSinglePath(
  sftpSessionId: string,
  localPath: string,
  remoteCwd: string,
  uploadFn: UploadFn
): Promise<void> {
  const stat = await invoke<FileStat>('local_fs_stat', { path: localPath })
  if (stat.isDir) {
    await uploadDirectory(sftpSessionId, localPath, remoteCwd, uploadFn)
    return
  }
  const fileName = localPath.split('/').pop() ?? localPath
  const remotePath = joinRemotePath(remoteCwd, fileName)
  await uploadFn(sftpSessionId, localPath, remotePath)
}

/** Recursively upload a local directory to remote via SFTP */
async function uploadDirectory(
  sftpSessionId: string,
  localDirPath: string,
  remoteParentPath: string,
  uploadFn: UploadFn
): Promise<void> {
  const dirName = localDirPath.split('/').pop() ?? localDirPath
  const remoteDirPath = joinRemotePath(remoteParentPath, dirName)

  // Create remote directory (ignore error if already exists)
  try {
    await invoke('sftp_mkdir', { sessionId: sftpSessionId, path: remoteDirPath })
  } catch {
    // Directory may already exist
  }

  const entries = await invoke<FileEntry[]>('local_fs_list_dir', {
    path: localDirPath
  })

  for (const entry of entries) {
    if (entry.isDir) {
      await uploadDirectory(sftpSessionId, entry.path, remoteDirPath, uploadFn)
    } else {
      const remotePath = `${remoteDirPath}/${entry.name}`
      await uploadFn(sftpSessionId, entry.path, remotePath)
    }
  }
}

export function useTerminalDragUpload({
  terminalAreaRef,
  activeSession,
  ensureSftpSession,
  upload,
  onNeedDirectoryPick
}: UseTerminalDragUploadParams): UseTerminalDragUploadResult {
  const [isDragOver, setIsDragOver] = useState(false)

  // Store latest values in refs to avoid re-subscribing to Tauri events
  const activeSessionRef = useRef(activeSession)
  activeSessionRef.current = activeSession
  const ensureSftpSessionRef = useRef(ensureSftpSession)
  ensureSftpSessionRef.current = ensureSftpSession
  const uploadRef = useRef(upload)
  uploadRef.current = upload
  const onNeedDirectoryPickRef = useRef(onNeedDirectoryPick)
  onNeedDirectoryPickRef.current = onNeedDirectoryPick

  // Pending drop paths for directory picker flow
  const pendingDropRef = useRef<{
    paths: string[]
    hostId: string
  } | null>(null)

  const isOverTerminal = useCallback(
    (x: number, y: number): boolean => {
      const el = terminalAreaRef.current
      if (!el) {
        return false
      }
      const rect = el.getBoundingClientRect()
      return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom
    },
    [terminalAreaRef]
  )

  const uploadPaths = useCallback(async (paths: string[], hostId: string, remoteCwd: string) => {
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
        await uploadSinglePath(sftpSessionId, localPath, remoteCwd, uploadRef.current)
      } catch (error) {
        const msg = error instanceof Error ? error.message : String(error)
        toast.error(`Upload failed: ${localPath.split('/').pop()}`, {
          description: msg
        })
      }
    }
  }, [])

  const handleDrop = useCallback(
    (paths: string[], position: { x: number; y: number }) => {
      if (!isOverTerminal(position.x, position.y)) {
        return
      }
      if (!paths || paths.length === 0) {
        return
      }

      const session = activeSessionRef.current
      if (!session || session.status !== 'connected') {
        toast.error('No active SSH connection')
        return
      }

      if (session.cwd) {
        uploadPaths(paths, session.hostId, session.cwd)
      } else {
        pendingDropRef.current = { paths, hostId: session.hostId }
        onNeedDirectoryPickRef.current()
      }
    },
    [isOverTerminal, uploadPaths]
  )

  const handleDirectoryPicked = useCallback(
    (remotePath: string) => {
      const pending = pendingDropRef.current
      if (!pending) {
        return
      }
      pendingDropRef.current = null
      uploadPaths(pending.paths, pending.hostId, remotePath)
    },
    [uploadPaths]
  )

  const handleDragDropEvent = useCallback(
    (type: string, position: { x: number; y: number }, paths?: string[]) => {
      if (type === 'enter') {
        if (isOverTerminal(position.x, position.y)) {
          setIsDragOver(true)
        }
      } else if (type === 'over') {
        setIsDragOver(isOverTerminal(position.x, position.y))
      } else if (type === 'drop') {
        setIsDragOver(false)
        if (paths) {
          handleDrop(paths, position)
        }
      } else if (type === 'leave') {
        setIsDragOver(false)
      }
    },
    [isOverTerminal, handleDrop]
  )

  useEffect(() => {
    let cancelled = false
    let cleanupFn: (() => void) | null = null

    const setup = async () => {
      const unlisten = await getCurrentWebview().onDragDropEvent((event) => {
        if (cancelled) {
          return
        }
        const payload = event.payload
        if (payload.type === 'leave') {
          handleDragDropEvent('leave', { x: 0, y: 0 })
          return
        }
        const paths = payload.type === 'drop' || payload.type === 'enter' ? payload.paths : undefined
        handleDragDropEvent(payload.type, payload.position, paths)
      })

      if (cancelled) {
        unlisten()
      } else {
        cleanupFn = unlisten
      }
    }

    setup()

    return () => {
      cancelled = true
      cleanupFn?.()
    }
  }, [handleDragDropEvent])

  return { isDragOver, handleDirectoryPicked }
}
