import { Dialog } from '@base-ui/react/dialog'
import { ChevronRight, Folder, Loader2 } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { Button } from '@/components/ui/button'
import { ScrollArea } from '@/components/ui/scroll-area'
import type { FileEntry } from '@/types/fs'

const TRAILING_SEGMENT_RE = /\/[^/]+\/?$/

interface RemoteDirectoryPickerProps {
  listDir: (path: string) => Promise<FileEntry[]>
  onCancel: () => void
  onSelect: (path: string) => void
  open: boolean
}

function pathSegments(path: string): { label: string; path: string }[] {
  const parts = path.split('/').filter(Boolean)
  const segments: { label: string; path: string }[] = [{ label: '/', path: '/' }]
  for (let i = 0; i < parts.length; i++) {
    segments.push({
      label: parts[i],
      path: `/${parts.slice(0, i + 1).join('/')}`
    })
  }
  return segments
}

function DirectoryListContent({
  currentPath,
  directories,
  error,
  loading,
  onNavigate,
  onNavigateUp
}: {
  currentPath: string
  directories: FileEntry[]
  error: string | null
  loading: boolean
  onNavigate: (path: string) => void
  onNavigateUp: () => void
}) {
  if (loading) {
    return (
      <div className="flex items-center justify-center py-8">
        <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
      </div>
    )
  }

  if (error) {
    return <div className="py-8 text-center text-destructive text-sm">{error}</div>
  }

  return (
    <ScrollArea className="max-h-64">
      <div className="flex flex-col gap-0.5">
        {currentPath !== '/' && (
          <button
            className="flex items-center gap-2 rounded-lg px-3 py-2 text-left text-sm transition-colors hover:bg-muted"
            onClick={onNavigateUp}
            type="button"
          >
            <Folder className="h-4 w-4 text-muted-foreground" />
            <span>..</span>
          </button>
        )}
        {directories.length === 0 && currentPath === '/' ? (
          <p className="py-4 text-center text-muted-foreground text-sm">No directories found.</p>
        ) : (
          directories.map((dir) => (
            <button
              className="flex items-center gap-2 rounded-lg px-3 py-2 text-left text-sm transition-colors hover:bg-muted"
              key={dir.path}
              onClick={() => onNavigate(dir.path)}
              type="button"
            >
              <Folder className="h-4 w-4 text-muted-foreground" />
              <span className="truncate">{dir.name}</span>
            </button>
          ))
        )}
      </div>
    </ScrollArea>
  )
}

export function RemoteDirectoryPicker({ listDir, onCancel, onSelect, open }: RemoteDirectoryPickerProps) {
  const [currentPath, setCurrentPath] = useState('/')
  const [directories, setDirectories] = useState<FileEntry[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const loadDirectory = useCallback(
    async (path: string) => {
      setLoading(true)
      setError(null)
      try {
        const entries = await listDir(path)
        const dirs = entries.filter((entry) => entry.isDir).sort((a, b) => a.name.localeCompare(b.name))
        setDirectories(dirs)
        setCurrentPath(path)
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err)
        setError(message)
      } finally {
        setLoading(false)
      }
    },
    [listDir]
  )

  useEffect(() => {
    if (open) {
      setCurrentPath('/')
      setDirectories([])
      setError(null)
      loadDirectory('/')
    }
  }, [open, loadDirectory])

  const handleNavigate = useCallback(
    (path: string) => {
      loadDirectory(path)
    },
    [loadDirectory]
  )

  const handleNavigateUp = useCallback(() => {
    if (currentPath === '/') {
      return
    }
    const parentPath = currentPath.replace(TRAILING_SEGMENT_RE, '') || '/'
    loadDirectory(parentPath)
  }, [currentPath, loadDirectory])

  const segments = pathSegments(currentPath)

  return (
    <Dialog.Root onOpenChange={(isOpen) => !isOpen && onCancel()} open={open}>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
        <Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-md -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg">
          <Dialog.Title className="font-medium text-base">Select Remote Directory</Dialog.Title>
          <Dialog.Description className="mt-1 text-muted-foreground text-sm">
            Browse and select a target directory for file upload.
          </Dialog.Description>

          <div className="mt-3 flex items-center gap-0.5 overflow-x-auto text-sm">
            {segments.map((segment, index) => (
              <span className="flex items-center" key={segment.path}>
                {index > 0 && <ChevronRight className="mx-0.5 h-3.5 w-3.5 shrink-0 text-muted-foreground" />}
                <button
                  className="shrink-0 rounded px-1 py-0.5 text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
                  onClick={() => handleNavigate(segment.path)}
                  type="button"
                >
                  {segment.label}
                </button>
              </span>
            ))}
          </div>

          <div className="mt-3">
            <DirectoryListContent
              currentPath={currentPath}
              directories={directories}
              error={error}
              loading={loading}
              onNavigate={handleNavigate}
              onNavigateUp={handleNavigateUp}
            />
          </div>

          <div className="mt-3 rounded-lg bg-muted px-3 py-2">
            <p className="truncate font-mono text-muted-foreground text-xs">{currentPath}</p>
          </div>

          <div className="mt-4 flex justify-end gap-2">
            <Dialog.Close
              render={
                <Button onClick={onCancel} variant="outline">
                  Cancel
                </Button>
              }
            />
            <Button onClick={() => onSelect(currentPath)}>Select</Button>
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
