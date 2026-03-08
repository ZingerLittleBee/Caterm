import { ArrowUpFromLine, ChevronDown, ChevronUp, X } from 'lucide-react'
import { useEffect, useState } from 'react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import type { TransferStatus, TransferTaskInfo } from '@/types/sftp'

function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  }
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
          Uploading{activeCount > 0 ? ` (${activeCount} active)` : ''} — {transfers.length} file
          {transfers.length > 1 ? 's' : ''}
        </span>
        {collapsed ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
      </button>
      {!collapsed && (
        <div className="max-h-40 overflow-y-auto">
          {transfers.map((task) => {
            const fileName = task.localPath.split('/').pop() ?? task.localPath
            const percent =
              task.totalBytes && task.totalBytes > 0
                ? Math.min((task.transferredBytes / task.totalBytes) * 100, 100)
                : 0
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
