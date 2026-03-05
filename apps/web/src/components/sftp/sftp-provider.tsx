import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import type { ReactNode } from 'react'
import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react'
import type { FileEntry, FileStat, SftpSessionInfo, TransferTaskInfo } from '@/types/sftp'

interface SftpContextValue {
  activeSftpSessionId: string | null
  cancelTransfer: (transferId: string) => Promise<void>
  chmod: (sessionId: string, path: string, mode: number) => Promise<void>
  close: (sessionId: string) => Promise<void>
  download: (sessionId: string, remotePath: string, localPath: string) => Promise<string>
  listDir: (sessionId: string, path: string) => Promise<FileEntry[]>
  mkdir: (sessionId: string, path: string) => Promise<void>
  openStandalone: (params: {
    authType: 'password' | 'key'
    hostId: string
    hostName: string
    hostname: string
    keyPassphrase?: string
    password?: string
    port?: number
    privateKey?: string
    username: string
  }) => Promise<string>
  readFile: (sessionId: string, path: string, maxSize?: number) => Promise<string>
  readlink: (sessionId: string, path: string) => Promise<string>
  remove: (sessionId: string, path: string) => Promise<void>
  rename: (sessionId: string, oldPath: string, newPath: string) => Promise<void>
  rmdir: (sessionId: string, path: string) => Promise<void>
  search: (sessionId: string, path: string, pattern: string) => Promise<FileEntry[]>
  sessions: Map<string, SftpSessionInfo>
  setActiveSftpSession: (sessionId: string | null) => void
  stat: (sessionId: string, path: string) => Promise<FileStat>
  transfers: TransferTaskInfo[]
  upload: (sessionId: string, localPath: string, remotePath: string) => Promise<string>
  writeFile: (sessionId: string, path: string, content: string) => Promise<void>
}

const SftpContext = createContext<SftpContextValue | null>(null)

export function useSftp(): SftpContextValue {
  const context = useContext(SftpContext)
  if (!context) {
    throw new Error('useSftp must be used within an SftpProvider')
  }
  return context
}

export function SftpProvider({ children }: { children: ReactNode }) {
  const [sessions, setSessions] = useState<Map<string, SftpSessionInfo>>(() => new Map())
  const [activeSftpSessionId, setActiveSftpSessionId] = useState<string | null>(null)
  const [transfers, setTransfers] = useState<TransferTaskInfo[]>([])

  const sessionsRef = useRef(sessions)
  sessionsRef.current = sessions

  const unlistenMap = useRef<Map<string, () => void>>(new Map())

  const openStandalone = useCallback(
    async (params: {
      authType: 'password' | 'key'
      hostId: string
      hostName: string
      hostname: string
      keyPassphrase?: string
      password?: string
      port?: number
      privateKey?: string
      username: string
    }): Promise<string> => {
      const sessionId = await invoke<string>('sftp_open', {
        hostId: params.hostId,
        hostname: params.hostname,
        port: params.port ?? 22,
        username: params.username,
        authType: params.authType,
        password: params.password,
        privateKey: params.privateKey,
        keyPassphrase: params.keyPassphrase
      })

      const sessionInfo: SftpSessionInfo = {
        hostId: params.hostId,
        hostName: params.hostName,
        id: sessionId,
        sshSessionId: null,
        status: 'connected'
      }

      // Listen for transfer progress events.
      const unlistenProgress = await listen<TransferTaskInfo>(`sftp-transfer-progress-${sessionId}`, (event) => {
        setTransfers((prev) => {
          const idx = prev.findIndex((t) => t.id === event.payload.id)
          if (idx === -1) {
            return [...prev, event.payload]
          }
          const next = [...prev]
          next[idx] = event.payload
          return next
        })
      })

      unlistenMap.current.set(sessionId, unlistenProgress)

      setSessions((prev) => {
        const next = new Map(prev)
        next.set(sessionId, sessionInfo)
        return next
      })

      setActiveSftpSessionId(sessionId)

      return sessionId
    },
    []
  )

  const close = useCallback(async (sessionId: string): Promise<void> => {
    try {
      await invoke('sftp_close', { sessionId })
    } catch {
      // Session may already be closed.
    }

    // Clean up event listener.
    const unlisten = unlistenMap.current.get(sessionId)
    if (unlisten) {
      unlisten()
      unlistenMap.current.delete(sessionId)
    }

    // Find a fallback session.
    let fallback: string | null = null
    for (const key of sessionsRef.current.keys()) {
      if (key !== sessionId) {
        fallback = key
        break
      }
    }

    setSessions((prev) => {
      const next = new Map(prev)
      next.delete(sessionId)
      return next
    })

    setActiveSftpSessionId((current) => (current === sessionId ? fallback : current))

    // Remove transfers associated with this session.
    setTransfers((prev) => prev.filter((t) => t.sftpSessionId !== sessionId))
  }, [])

  const listDir = useCallback((sessionId: string, path: string): Promise<FileEntry[]> => {
    return invoke<FileEntry[]>('sftp_list_dir', { sessionId, path })
  }, [])

  const stat = useCallback((sessionId: string, path: string): Promise<FileStat> => {
    return invoke<FileStat>('sftp_stat', { sessionId, path })
  }, [])

  const mkdir = useCallback(async (sessionId: string, path: string): Promise<void> => {
    await invoke('sftp_mkdir', { sessionId, path })
  }, [])

  const rmdir = useCallback(async (sessionId: string, path: string): Promise<void> => {
    await invoke('sftp_rmdir', { sessionId, path })
  }, [])

  const remove = useCallback(async (sessionId: string, path: string): Promise<void> => {
    await invoke('sftp_remove', { sessionId, path })
  }, [])

  const rename = useCallback(async (sessionId: string, oldPath: string, newPath: string): Promise<void> => {
    await invoke('sftp_rename', { sessionId, from: oldPath, to: newPath })
  }, [])

  const chmod = useCallback(async (sessionId: string, path: string, mode: number): Promise<void> => {
    await invoke('sftp_chmod', { sessionId, path, mode })
  }, [])

  const readFile = useCallback((sessionId: string, path: string, maxSize?: number): Promise<string> => {
    return invoke<string>('sftp_read_file', {
      sessionId,
      path,
      maxSize: maxSize ?? null
    })
  }, [])

  const writeFile = useCallback(async (sessionId: string, path: string, content: string): Promise<void> => {
    await invoke('sftp_write_file', { sessionId, path, content })
  }, [])

  const readlink = useCallback((sessionId: string, path: string): Promise<string> => {
    return invoke<string>('sftp_readlink', { sessionId, path })
  }, [])

  const search = useCallback((sessionId: string, path: string, pattern: string): Promise<FileEntry[]> => {
    return invoke<FileEntry[]>('sftp_search', {
      sessionId,
      path,
      pattern
    })
  }, [])

  const upload = useCallback((sessionId: string, localPath: string, remotePath: string): Promise<string> => {
    return invoke<string>('sftp_upload', {
      sessionId,
      localPath,
      remotePath
    })
  }, [])

  const download = useCallback((sessionId: string, remotePath: string, localPath: string): Promise<string> => {
    return invoke<string>('sftp_download', {
      sessionId,
      remotePath,
      localPath
    })
  }, [])

  const cancelTransfer = useCallback(async (transferId: string): Promise<void> => {
    await invoke('sftp_transfer_cancel', { taskId: transferId })
  }, [])

  const setActiveSftpSession = useCallback((sessionId: string | null) => {
    setActiveSftpSessionId(sessionId)
  }, [])

  // Cleanup all sessions and listeners when the provider unmounts.
  useEffect(() => {
    return () => {
      for (const [, unlisten] of unlistenMap.current) {
        unlisten()
      }
      unlistenMap.current.clear()

      for (const sid of sessionsRef.current.keys()) {
        invoke('sftp_close', { sessionId: sid }).catch(() => {
          // Session may already be closed.
        })
      }
    }
  }, [])

  return (
    <SftpContext.Provider
      value={{
        activeSftpSessionId,
        cancelTransfer,
        chmod,
        close,
        download,
        listDir,
        mkdir,
        openStandalone,
        readFile,
        readlink,
        remove,
        rename,
        rmdir,
        search,
        sessions,
        setActiveSftpSession,
        stat,
        transfers,
        upload,
        writeFile
      }}
    >
      {children}
    </SftpContext.Provider>
  )
}
