import type { QueryClient } from '@tanstack/react-query'

import { getSshHostsSyncQueryOptions, getTerminalSettingsSyncQueryOptions } from '@/lib/sync-query-options'

type Prefetcher = () => Promise<unknown>

export interface RoutePrefetchResult {
  hosts: PromiseSettledResult<unknown>
  settings?: PromiseSettledResult<unknown>
}

function settle(prefetcher: Prefetcher): Promise<PromiseSettledResult<unknown>> {
  return Promise.resolve()
    .then(prefetcher)
    .then(
      (value) => ({ status: 'fulfilled', value }) as const,
      (reason) => ({ status: 'rejected', reason }) as const
    )
}

export async function runPrefetchBundle(prefetchers: {
  hosts: Prefetcher
  settings?: Prefetcher
}): Promise<RoutePrefetchResult> {
  if (!prefetchers.settings) {
    const hosts = await settle(prefetchers.hosts)
    return { hosts }
  }

  const [hosts, settings] = await Promise.all([settle(prefetchers.hosts), settle(prefetchers.settings)])

  return { hosts, settings }
}

export function prefetchSshRouteData(queryClient: QueryClient) {
  return runPrefetchBundle({
    hosts: () => queryClient.fetchQuery(getSshHostsSyncQueryOptions()),
    settings: () => queryClient.fetchQuery(getTerminalSettingsSyncQueryOptions())
  })
}

export function prefetchSftpRouteData(queryClient: QueryClient) {
  return runPrefetchBundle({
    hosts: () => queryClient.fetchQuery(getSshHostsSyncQueryOptions())
  })
}
