import { ArrowDownToLine, ArrowUpFromLine, ChevronDown, ChevronUp, X } from 'lucide-react'
import { useState } from 'react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import type { TransferStatus, TransferTaskInfo } from '@/types/sftp'
import { useSftp } from './sftp-provider'

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

function ProgressBar({ total, transferred }: { total: number | null; transferred: number }) {
  const percent = total && total > 0 ? Math.min((transferred / total) * 100, 100) : 0
  return (
    <div className="h-2 w-full overflow-hidden rounded-full bg-muted">
      <div className="h-full rounded-full bg-primary transition-all" style={{ width: `${percent}%` }} />
    </div>
  )
}

function TransferRow({ onCancel, task }: { onCancel: (id: string) => void; task: TransferTaskInfo }) {
  const fileName =
    task.kind === 'upload'
      ? (task.localPath.split('/').pop() ?? task.localPath)
      : (task.remotePath.split('/').pop() ?? task.remotePath)

  const canCancel = task.status === 'active' || task.status === 'pending'

  return (
    <div className="flex items-center gap-3 border-b px-3 py-2 last:border-b-0">
      {task.kind === 'upload' ? (
        <ArrowUpFromLine className="h-4 w-4 shrink-0 text-blue-500" />
      ) : (
        <ArrowDownToLine className="h-4 w-4 shrink-0 text-green-500" />
      )}
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="truncate text-sm">{fileName}</span>
          <Badge variant={statusVariant(task.status)}>{task.status}</Badge>
        </div>
        <div className="mt-1 flex items-center gap-2">
          <div className="min-w-0 flex-1">
            <ProgressBar total={task.totalBytes} transferred={task.transferredBytes} />
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
}

export function SftpTransferQueue() {
  const { cancelTransfer, transfers } = useSftp()
  const [collapsed, setCollapsed] = useState(false)

  if (transfers.length === 0) {
    return null
  }

  return (
    <div className="border-t bg-background">
      <button
        className="flex w-full items-center justify-between px-3 py-1.5 text-sm hover:bg-muted"
        onClick={() => setCollapsed((prev) => !prev)}
        type="button"
      >
        <span className="font-medium">Transfers ({transfers.length})</span>
        {collapsed ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
      </button>
      {!collapsed && (
        <div className="max-h-48 overflow-y-auto">
          {transfers.map((task) => (
            <TransferRow key={task.id} onCancel={cancelTransfer} task={task} />
          ))}
        </div>
      )}
    </div>
  )
}
