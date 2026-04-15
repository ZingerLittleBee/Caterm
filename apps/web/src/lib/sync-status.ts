export interface SyncBannerCopy {
  description: string
  title: string
}

export function getHostSyncPresentation(input: { hostCount: number; isError: boolean; isPending: boolean }) {
  if (input.isError) {
    return {
      banner: {
        title: 'SSH hosts unavailable',
        description: 'Failed to sync your saved SSH hosts. Retry to restore them.'
      } satisfies SyncBannerCopy,
      disableActions: true,
      showEmptyState: false,
      showLoadingState: false
    }
  }

  if (input.isPending && input.hostCount === 0) {
    return {
      banner: null,
      disableActions: true,
      showEmptyState: false,
      showLoadingState: true
    }
  }

  return {
    banner: null,
    disableActions: false,
    showEmptyState: input.hostCount === 0,
    showLoadingState: false
  }
}

export function getTerminalSettingsPresentation(input: {
  hasCachedSettings: boolean
  hasError: boolean
  hasSuccessfulServerSync: boolean
}) {
  if (input.hasError) {
    return {
      allowEditing: false,
      banner: {
        title: 'Terminal settings out of sync',
        description: input.hasCachedSettings
          ? 'Using cached terminal settings until sync succeeds.'
          : 'Using built-in terminal defaults until sync succeeds.'
      } satisfies SyncBannerCopy
    }
  }

  return {
    allowEditing: input.hasSuccessfulServerSync,
    banner: null
  }
}
