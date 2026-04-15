import { SyncStatusBanner } from '@/components/sync/sync-status-banner'
import { useTerminalSettings } from '@/components/terminal/terminal-settings-provider'

interface TerminalSettingsSyncBannerProps {
  className?: string
}

export function TerminalSettingsSyncBanner({ className }: TerminalSettingsSyncBannerProps) {
  const { isReadOnlyFallback, retrySync, syncBanner } = useTerminalSettings()

  if (!(isReadOnlyFallback && syncBanner)) {
    return null
  }

  return (
    <div className={className}>
      <SyncStatusBanner description={syncBanner.description} onRetry={retrySync} title={syncBanner.title} />
    </div>
  )
}
