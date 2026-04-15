import { orpc } from '@/lib/orpc'

export function getSshHostsSyncQueryOptions() {
  return {
    ...orpc.sshHost.list.queryOptions(),
    meta: {
      suppressGlobalErrorToast: true
    } as const
  }
}

export function getTerminalSettingsSyncQueryOptions() {
  return {
    ...orpc.terminalSettings.get.queryOptions(),
    staleTime: 0,
    meta: {
      suppressGlobalErrorToast: true
    } as const
  }
}
