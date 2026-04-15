// @ts-expect-error bun:test is available at runtime in Bun but not declared in this web tsconfig
import { expect, test } from 'bun:test'

import { getHostSyncPresentation } from './sync-status'

test('host fetch failure disables actions and hides the empty state', () => {
  expect(
    getHostSyncPresentation({
      hostCount: 0,
      isError: true,
      isPending: false
    })
  ).toEqual({
    banner: {
      title: 'SSH hosts unavailable',
      description: 'Failed to sync your saved SSH hosts. Retry to restore them.'
    },
    disableActions: true,
    showEmptyState: false,
    showLoadingState: false
  })
})

test('host initial load shows loading state instead of empty state', () => {
  expect(
    getHostSyncPresentation({
      hostCount: 0,
      isError: false,
      isPending: true
    })
  ).toEqual({
    banner: null,
    disableActions: true,
    showEmptyState: false,
    showLoadingState: true
  })
})
