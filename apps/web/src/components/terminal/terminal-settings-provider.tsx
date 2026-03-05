import { useMutation, useQuery } from '@tanstack/react-query'
import { createContext, type ReactNode, useCallback, useContext, useEffect, useMemo } from 'react'
import { toast } from 'sonner'
import { client, queryClient } from '@/lib/orpc'
import { readSettingsCache, writeSettingsCache } from '@/lib/terminal-settings-cache'
import { DEFAULT_TERMINAL_SETTINGS, resolveSettings } from '@/lib/terminal-themes'
import type { TerminalSettings, TerminalSettingsState } from '@/types/ssh'

interface TerminalSettingsContextValue {
  clearHostOverrides: (hostId: string) => void
  getSettingsForHost: (hostId: string) => TerminalSettings
  isLoading: boolean
  settings: TerminalSettings
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

const SETTINGS_QUERY_KEY = ['terminalSettings', 'get'] as const

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
  const { data, isLoading } = useQuery({
    queryKey: SETTINGS_QUERY_KEY,
    queryFn: async () => {
      const raw = await client.terminalSettings.get()
      return normalizeApiData(raw)
    },
    placeholderData: () => {
      const cached = readSettingsCache()
      return cached ? normalizeApiData(cached) : undefined
    },
    staleTime: 60_000
  })

  useEffect(() => {
    if (data) {
      writeSettingsCache(data)
    }
  }, [data])

  const upsertMutation = useMutation({
    mutationFn: (input: {
      global?: Partial<TerminalSettings>
      hostOverrides?: Record<string, Partial<TerminalSettings>>
    }) => client.terminalSettings.upsert(input),
    onMutate: async (input) => {
      await queryClient.cancelQueries({ queryKey: SETTINGS_QUERY_KEY })
      const previous = queryClient.getQueryData<SettingsData>(SETTINGS_QUERY_KEY)
      queryClient.setQueryData<SettingsData>(SETTINGS_QUERY_KEY, (old) => {
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
        queryClient.setQueryData(SETTINGS_QUERY_KEY, context.previous)
      }
      toast.error('Failed to save settings')
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: SETTINGS_QUERY_KEY })
    }
  })

  const deleteHostOverrideMutation = useMutation({
    mutationFn: (input: { hostId: string }) => client.terminalSettings.deleteHostOverride(input),
    onMutate: async (input) => {
      await queryClient.cancelQueries({ queryKey: SETTINGS_QUERY_KEY })
      const previous = queryClient.getQueryData<SettingsData>(SETTINGS_QUERY_KEY)
      queryClient.setQueryData<SettingsData>(SETTINGS_QUERY_KEY, (old) => {
        if (!old) {
          return old
        }
        const { [input.hostId]: _, ...rest } = old.hostOverrides
        return { global: old.global, hostOverrides: rest }
      })
      return { previous }
    },
    onError: (_err, _input, context) => {
      if (context?.previous) {
        queryClient.setQueryData(SETTINGS_QUERY_KEY, context.previous)
      }
      toast.error('Failed to delete host overrides')
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: SETTINGS_QUERY_KEY })
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
      upsertMutation.mutate({ global: partial })
    },
    [upsertMutation.mutate]
  )

  const updateHostOverrides = useCallback(
    (hostId: string, partial: Partial<TerminalSettings>) => {
      upsertMutation.mutate({
        hostOverrides: { [hostId]: partial }
      })
    },
    [upsertMutation.mutate]
  )

  const clearHostOverrides = useCallback(
    (hostId: string) => {
      deleteHostOverrideMutation.mutate({ hostId })
    },
    [deleteHostOverrideMutation.mutate]
  )

  return (
    <TerminalSettingsContext.Provider
      value={{
        settings: globalSettings,
        isLoading,
        getSettingsForHost,
        updateGlobal,
        updateHostOverrides,
        clearHostOverrides
      }}
    >
      {children}
    </TerminalSettingsContext.Provider>
  )
}
