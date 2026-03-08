import { Loader2 } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { FilePanel } from '@/components/file-panel'
import { createLocalFileOps, createSftpFileOps, getHomeDir, openInSystem } from '@/lib/file-operations'
import type { FileEntry } from '@/types/fs'
import { useSftp } from './sftp-provider'

interface SftpFilePanelProps {
  onDownload?: (entries: FileEntry[]) => void
  onDrop?: (entries: FileEntry[], targetPath: string) => void
  onPathChange?: (path: string) => void
  onUpload?: () => void
  refreshTrigger?: number
  sftpSessionId?: string
  source: 'local' | 'remote'
}

export function SftpFilePanel({
  source,
  sftpSessionId,
  onUpload,
  onDownload,
  onDrop,
  onPathChange: onPathChangeProp,
  refreshTrigger
}: SftpFilePanelProps) {
  const sftp = useSftp()
  const session = sftpSessionId ? (sftp.sessions.get(sftpSessionId) ?? null) : null

  const operations = useMemo(() => {
    if (source === 'local') {
      return createLocalFileOps()
    }
    if (sftpSessionId) {
      return createSftpFileOps(sftpSessionId, sftp)
    }
    return null
  }, [source, sftpSessionId, sftp])

  const [initialPath, setInitialPath] = useState('/')
  const [ready, setReady] = useState(source === 'remote')

  useEffect(() => {
    if (source === 'local') {
      const saved = localStorage.getItem('caterm:local-file-panel:lastPath')
      if (saved) {
        setInitialPath(saved)
        setReady(true)
      } else {
        getHomeDir()
          .then((home) => {
            setInitialPath(home)
            setReady(true)
          })
          .catch(() => {
            setInitialPath('/')
            setReady(true)
          })
      }
    }
  }, [source])

  const handlePathChange = useCallback(
    (path: string) => {
      if (source === 'local') {
        localStorage.setItem('caterm:local-file-panel:lastPath', path)
      }
      onPathChangeProp?.(path)
    },
    [source, onPathChangeProp]
  )

  const extraContextMenuItems = useMemo(
    () => (source === 'local' ? { onOpenInSystem: (entry: FileEntry) => openInSystem(entry.path) } : undefined),
    [source]
  )

  if (!(operations && ready)) {
    return (
      <div className="flex h-full items-center justify-center">
        <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
      </div>
    )
  }

  return (
    <FilePanel
      extraContextMenuItems={extraContextMenuItems}
      hostId={session?.hostId}
      initialPath={initialPath}
      key={initialPath}
      onDownload={onDownload}
      onDrop={onDrop}
      onPathChange={handlePathChange}
      onUpload={onUpload}
      operations={operations}
      refreshTrigger={refreshTrigger}
      source={source}
    />
  )
}
