import { Dialog } from '@base-ui/react/dialog'
import { Loader2 } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { useSftp } from './sftp-provider'

interface SftpEditorDialogProps {
  onClose: () => void
  onSaved?: () => void
  open: boolean
  path: string
  sessionId: string
}

export function SftpEditorDialog({ onClose, onSaved, open, path, sessionId }: SftpEditorDialogProps) {
  const { readFile, writeFile } = useSftp()
  const [content, setContent] = useState('')
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const loadContent = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const text = await readFile(sessionId, path, 1024 * 1024)
      setContent(text)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      setError(message)
      toast.error('Failed to load file', { description: message })
    } finally {
      setLoading(false)
    }
  }, [readFile, sessionId, path])

  useEffect(() => {
    if (open) {
      loadContent()
    }
  }, [open, loadContent])

  const handleSave = useCallback(async () => {
    setSaving(true)
    try {
      await writeFile(sessionId, path, content)
      toast.success('File saved')
      onSaved?.()
      onClose()
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      toast.error('Failed to save file', { description: message })
    } finally {
      setSaving(false)
    }
  }, [writeFile, sessionId, path, content, onSaved, onClose])

  const fileName = path.split('/').pop() ?? path

  return (
    <Dialog.Root onOpenChange={(isOpen) => !isOpen && onClose()} open={open}>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
        <Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-2xl -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg">
          <Dialog.Title className="font-medium text-base">Edit: {fileName}</Dialog.Title>
          <Dialog.Description className="mt-1 text-muted-foreground text-xs">{path}</Dialog.Description>

          <div className="mt-4">
            {loading && (
              <div className="flex h-32 items-center justify-center">
                <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
              </div>
            )}
            {error && <div className="rounded-md bg-destructive/10 p-3 text-destructive text-sm">{error}</div>}
            {!(loading || error) && (
              <textarea
                className="h-80 w-full resize-none rounded-md border bg-muted p-3 font-mono text-sm focus:outline-none focus:ring-2 focus:ring-ring"
                onChange={(e) => setContent(e.target.value)}
                value={content}
              />
            )}
          </div>

          <div className="mt-4 flex justify-end gap-2">
            <Dialog.Close
              render={
                <Button onClick={onClose} variant="outline">
                  Cancel
                </Button>
              }
            />
            <Button disabled={loading || saving || !!error} onClick={handleSave}>
              {saving ? 'Saving...' : 'Save'}
            </Button>
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
