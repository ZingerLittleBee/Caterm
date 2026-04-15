import { SyncStatusBanner } from '@/components/sync/sync-status-banner'
import { useTerminalSettings } from '@/components/terminal/terminal-settings-provider'

export function TerminalSettingsSyncBanner() {
  const { isReadOnlyFallback, retrySync, syncBanner } = useTerminalSettings()

  if (!(isReadOnlyFallback && syncBanner)) {
    return null
  }

  return <SyncStatusBanner description={syncBanner.description} onRetry={retrySync} title={syncBanner.title} />
}
