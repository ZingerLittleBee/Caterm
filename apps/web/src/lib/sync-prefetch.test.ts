// @ts-expect-error bun:test is available at runtime in Bun but not declared in this web tsconfig
import { expect, test } from 'bun:test'

import { runPrefetchBundle } from './sync-prefetch'

test('runPrefetchBundle returns settled results without short-circuiting when one request fails', async () => {
  const result = await runPrefetchBundle({
    hosts: () => Promise.resolve('hosts-ok'),
    settings: () => Promise.reject(new Error('settings-down'))
  })

  expect(result.hosts.status).toBe('fulfilled')
  expect(result.settings?.status).toBe('rejected')
})

test('runPrefetchBundle omits settings result for routes that only need hosts', async () => {
  const result = await runPrefetchBundle({
    hosts: async () => 'hosts-ok'
  })

  expect(result.hosts.status).toBe('fulfilled')
  expect(result.settings).toBeUndefined()
})

test('runPrefetchBundle starts hosts and settings prefetchers in the same turn', async () => {
  const calls: string[] = []

  await runPrefetchBundle({
    hosts: () => {
      calls.push('hosts')
      return Promise.resolve('hosts-ok')
    },
    settings: () => {
      calls.push('settings')
      return Promise.resolve('settings-ok')
    }
  })

  expect(calls).toEqual(['hosts', 'settings'])
})
