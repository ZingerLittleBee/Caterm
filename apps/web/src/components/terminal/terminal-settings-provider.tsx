import { useMutation, useQuery } from '@tanstack/react-query'
import { createContext, type ReactNode, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import { toast } from 'sonner'
import { client, queryClient } from '@/lib/orpc'
import { getTerminalSettingsSyncQueryOptions } from '@/lib/sync-query-options'
import type { SyncBannerCopy } from '@/lib/sync-status'
import { getTerminalSettingsPresentation } from '@/lib/sync-status'
import { readSettingsCache, writeSettingsCache } from '@/lib/terminal-settings-cache'
import { DEFAULT_TERMINAL_SETTINGS, resolveSettings } from '@/lib/terminal-themes'
import type { TerminalSettings, TerminalSettingsState } from '@/types/ssh'

interface TerminalSettingsContextValue {
  clearHostOverrides: (hostId: string) => void
  getSettingsForHost: (hostId: string) => TerminalSettings
  isLoading: boolean
  isReadOnlyFallback: boolean
  retrySync: () => Promise<unknown>
  settings: TerminalSettings
  syncBanner: SyncBannerCopy | null
  updateGlobal: (partial: Partial<TerminalSettings>) => void
  updateHostOverrides: (hostId: string, partial: Partial<TerminalSettings>) => void
}

const TerminalSettingsContext = createContext<TerminalSettingsContextValue | null>(null)

export function useTerminalSettings(): TerminalSettingsContextValue {
  const context = useContext(TerminalSettingsContext)
  if (!context) {
    throw new Error('useTerminalSettings must be used within a TerminalSettingsProvider')
  }
  return context
}

function normalizeApiData(raw: unknown): {
  global: TerminalSettings
  hostOverrides: Record<string, Partial<TerminalSettings>>
} {
  if (!raw || typeof raw !== 'object') {
    return { global: DEFAULT_TERMINAL_SETTINGS, hostOverrides: {} }
  }
  const rawData = raw as {
    global?: Record<string, unknown>
    hostOverrides?: Record<string, Partial<TerminalSettings>>
  }
  return {
    global: {
      ...DEFAULT_TERMINAL_SETTINGS,
      ...rawData.global
    } as TerminalSettings,
    hostOverrides: (rawData.hostOverrides ?? {}) as Record<string, Partial<TerminalSettings>>
  }
}

type SettingsData = ReturnType<typeof normalizeApiData>

export function TerminalSettingsProvider({ children }: { children: ReactNode }) {
  const [bootCache] = useState(() => readSettingsCache())
  const bootCacheData = useMemo(() => (bootCache ? normalizeApiData(bootCache) : undefined), [bootCache])
  const terminalSettingsQueryOptions = useMemo(() => getTerminalSettingsSyncQueryOptions(), [])
  const { data, isError, isPending, isPlaceholderData, refetch } = useQuery({
    ...terminalSettingsQueryOptions,
    placeholderData: bootCache,
    select: normalizeApiData
  })

  const presentation = getTerminalSettingsPresentation({
    hasCachedSettings: bootCacheData !== undefined || data !== undefined,
    hasError: isError,
    hasSuccessfulServerSync: data !== undefined && !isError && !isPlaceholderData
  })
  const isReadOnlyFallback = !presentation.allowEditing
  const retrySync = useCallback(() => refetch(), [refetch])
  const isLoading = isPending && data === undefined

  useEffect(() => {
    if (data && !isPlaceholderData) {
      writeSettingsCache(data)
    }
  }, [data, isPlaceholderData])

  const upsertMutation = useMutation({
    mutationFn: (input: {
      global?: Partial<TerminalSettings>
      hostOverrides?: Record<string, Partial<TerminalSettings>>
    }) => client.terminalSettings.upsert(input),
    onMutate: async (input) => {
      await queryClient.cancelQueries({ queryKey: terminalSettingsQueryOptions.queryKey })
      const previous = queryClient.getQueryData<SettingsData>(terminalSettingsQueryOptions.queryKey)
      queryClient.setQueryData<SettingsData>(terminalSettingsQueryOptions.queryKey, (old) => {
        if (!old) {
          return old
        }
        const newGlobal = input.global ? { ...old.global, ...input.global } : old.global
        const newOverrides = { ...old.hostOverrides }
        if (input.hostOverrides) {
          for (const [hostId, overrideValues] of Object.entries(input.hostOverrides)) {
            newOverrides[hostId] = {
              ...(newOverrides[hostId] ?? {}),
              ...overrideValues
            }
          }
        }
        return {
          global: newGlobal as TerminalSettings,
          hostOverrides: newOverrides
        }
      })
      return { previous }
    },
    onError: (_err, _input, context) => {
      if (context?.previous) {
        queryClient.setQueryData(terminalSettingsQueryOptions.queryKey, context.previous)
      }
      toast.error('Failed to save settings')
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: terminalSettingsQueryOptions.queryKey })
    }
  })

  const deleteHostOverrideMutation = useMutation({
    mutationFn: (input: { hostId: string }) => client.terminalSettings.deleteHostOverride(input),
    onMutate: async (input) => {
      await queryClient.cancelQueries({ queryKey: terminalSettingsQueryOptions.queryKey })
      const previous = queryClient.getQueryData<SettingsData>(terminalSettingsQueryOptions.queryKey)
      queryClient.setQueryData<SettingsData>(terminalSettingsQueryOptions.queryKey, (old) => {
        if (!old) {
          return old
        }
        const { [input.hostId]: _deletedOverride, ...rest } = old.hostOverrides
        return { global: old.global, hostOverrides: rest }
      })
      return { previous }
    },
    onError: (_err, _input, context) => {
      if (context?.previous) {
        queryClient.setQueryData(terminalSettingsQueryOptions.queryKey, context.previous)
      }
      toast.error('Failed to delete host overrides')
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: terminalSettingsQueryOptions.queryKey })
    }
  })

  const globalSettings = data?.global ?? DEFAULT_TERMINAL_SETTINGS
  const hostOverridesRecord = data?.hostOverrides ?? {}

  const state: TerminalSettingsState = useMemo(
    () => ({
      global: globalSettings,
      hostOverrides: new Map(Object.entries(hostOverridesRecord))
    }),
    [globalSettings, hostOverridesRecord]
  )

  const getSettingsForHost = useCallback((hostId: string): TerminalSettings => resolveSettings(state, hostId), [state])

  const updateGlobal = useCallback(
    (partial: Partial<TerminalSettings>) => {
      if (isReadOnlyFallback) {
        return
      }
      upsertMutation.mutate({ global: partial })
    },
    [isReadOnlyFallback, upsertMutation]
  )

  const updateHostOverrides = useCallback(
    (hostId: string, partial: Partial<TerminalSettings>) => {
      if (isReadOnlyFallback) {
        return
      }
      upsertMutation.mutate({
        hostOverrides: { [hostId]: partial }
      })
    },
    [isReadOnlyFallback, upsertMutation]
  )

  const clearHostOverrides = useCallback(
    (hostId: string) => {
      if (isReadOnlyFallback) {
        return
      }
      deleteHostOverrideMutation.mutate({ hostId })
    },
    [deleteHostOverrideMutation, isReadOnlyFallback]
  )

  return (
    <TerminalSettingsContext.Provider
      value={{
        settings: globalSettings,
        isLoading,
        isReadOnlyFallback,
        getSettingsForHost,
        retrySync,
        syncBanner: presentation.banner,
        updateGlobal,
        updateHostOverrides,
        clearHostOverrides
      }}
    >
      {children}
    </TerminalSettingsContext.Provider>
  )
}
