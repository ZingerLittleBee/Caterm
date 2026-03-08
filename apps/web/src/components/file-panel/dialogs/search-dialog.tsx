import { Dialog } from '@base-ui/react/dialog'
import { File, Folder, Loader2, Search } from 'lucide-react'
import { useCallback, useState } from 'react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ScrollArea } from '@/components/ui/scroll-area'
import type { FileEntry } from '@/types/fs'

interface SearchDialogProps {
  basePath: string
  onClose: () => void
  onNavigate: (path: string) => void
  open: boolean
  search: (path: string, pattern: string) => Promise<FileEntry[]>
}

export function SearchDialog({ basePath, onClose, onNavigate, open, search }: SearchDialogProps) {
  const [pattern, setPattern] = useState('')
  const [results, setResults] = useState<FileEntry[]>([])
  const [searching, setSearching] = useState(false)

  const handleSearch = useCallback(async () => {
    if (!pattern.trim()) {
      return
    }
    setSearching(true)
    try {
      const found = await search(basePath, pattern.trim())
      setResults(found)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      toast.error('Search failed', { description: message })
    } finally {
      setSearching(false)
    }
  }, [search, basePath, pattern])

  const handleResultClick = useCallback(
    (entry: FileEntry) => {
      const parentPath = entry.path.substring(0, entry.path.lastIndexOf('/'))
      onNavigate(parentPath || '/')
      onClose()
    },
    [onNavigate, onClose]
  )

  const handleOpenChange = useCallback(
    (isOpen: boolean) => {
      if (!isOpen) {
        onClose()
        setPattern('')
        setResults([])
      }
    },
    [onClose]
  )

  return (
    <Dialog.Root onOpenChange={handleOpenChange} open={open}>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
        <Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-md -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg">
          <Dialog.Title className="font-medium text-base">Search Files</Dialog.Title>
          <Dialog.Description className="mt-1 text-muted-foreground text-sm">Search in {basePath}</Dialog.Description>

          <div className="mt-4 flex gap-2">
            <Input
              autoFocus
              onChange={(e) => setPattern(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  handleSearch()
                }
              }}
              placeholder="File name pattern..."
              value={pattern}
            />
            <Button disabled={searching || !pattern.trim()} onClick={handleSearch} size="icon">
              {searching ? <Loader2 className="h-4 w-4 animate-spin" /> : <Search className="h-4 w-4" />}
            </Button>
          </div>

          {results.length > 0 && (
            <ScrollArea className="mt-4 max-h-64">
              <div className="space-y-0.5">
                {results.map((entry) => (
                  <button
                    className="flex w-full items-center gap-2 rounded-sm px-2 py-1.5 text-left text-sm hover:bg-accent"
                    key={entry.path}
                    onClick={() => handleResultClick(entry)}
                    type="button"
                  >
                    {entry.isDir ? (
                      <Folder className="h-4 w-4 shrink-0 text-yellow-500" />
                    ) : (
                      <File className="h-4 w-4 shrink-0 text-muted-foreground" />
                    )}
                    <div className="min-w-0 flex-1">
                      <div className="truncate font-medium">{entry.name}</div>
                      <div className="truncate text-muted-foreground text-xs">{entry.path}</div>
                    </div>
                  </button>
                ))}
              </div>
            </ScrollArea>
          )}

          {results.length === 0 && searching === false && pattern && (
            <p className="mt-4 text-center text-muted-foreground text-sm">No results found.</p>
          )}

          <div className="mt-4 flex justify-end">
            <Dialog.Close
              render={
                <Button onClick={onClose} variant="outline">
                  Close
                </Button>
              }
            />
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
