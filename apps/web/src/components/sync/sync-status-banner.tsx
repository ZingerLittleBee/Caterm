import { Button } from '@/components/ui/button'

interface SyncStatusBannerProps {
  description: string
  onRetry?: () => void
  title: string
}

export function SyncStatusBanner({ title, description, onRetry }: SyncStatusBannerProps) {
  return (
    <div className="rounded-lg border border-destructive/30 bg-destructive/5 px-3 py-3">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="font-medium text-sm">{title}</p>
          <p className="mt-1 text-muted-foreground text-sm">{description}</p>
        </div>
        {onRetry ? (
          <Button onClick={onRetry} size="sm" type="button" variant="outline">
            Retry
          </Button>
        ) : null}
      </div>
    </div>
  )
}
