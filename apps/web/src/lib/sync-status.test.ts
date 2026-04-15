// @ts-expect-error bun:test is available at runtime in Bun but not declared in this web tsconfig
import { expect, test } from 'bun:test'

import { getHostSyncPresentation, getTerminalSettingsPresentation } from './sync-status'

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

test('host fetch failure still hides rendered hosts when cached data exists', () => {
  expect(
    getHostSyncPresentation({
      hostCount: 2,
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

test('terminal settings error uses cached settings copy when available', () => {
  expect(
    getTerminalSettingsPresentation({
      hasCachedSettings: true,
      hasError: true,
      hasSuccessfulServerSync: false
    })
  ).toEqual({
    allowEditing: false,
    banner: {
      title: 'Terminal settings out of sync',
      description: 'Using cached terminal settings until sync succeeds.'
    }
  })
})

test('terminal settings error uses built-in defaults copy when no cache exists', () => {
  expect(
    getTerminalSettingsPresentation({
      hasCachedSettings: false,
      hasError: true,
      hasSuccessfulServerSync: false
    })
  ).toEqual({
    allowEditing: false,
    banner: {
      title: 'Terminal settings out of sync',
      description: 'Using built-in terminal defaults until sync succeeds.'
    }
  })
})

test('terminal settings success allows editing without a banner', () => {
  expect(
    getTerminalSettingsPresentation({
      hasCachedSettings: false,
      hasError: false,
      hasSuccessfulServerSync: true
    })
  ).toEqual({
    allowEditing: true,
    banner: null
  })
})
