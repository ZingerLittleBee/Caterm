import { db } from '@Caterm/db'
import { terminalSettings } from '@Caterm/db/schema/terminal-settings'
import { eq } from 'drizzle-orm'
import z from 'zod'

import { protectedProcedure } from '../index'

const DEFAULT_GLOBAL = {
  bellStyle: 'none',
  cursorBlink: true,
  cursorInactiveStyle: 'outline',
  cursorStyle: 'block',
  fontFamily: 'monospace',
  fontSize: 14,
  letterSpacing: 0,
  lineHeight: 1.0,
  scrollback: 1000,
  themeName: 'default',
  themeOverrides: {}
}

const themeOverridesSchema = z
  .object({
    background: z.string().optional(),
    black: z.string().optional(),
    blue: z.string().optional(),
    brightBlack: z.string().optional(),
    brightBlue: z.string().optional(),
    brightCyan: z.string().optional(),
    brightGreen: z.string().optional(),
    brightMagenta: z.string().optional(),
    brightRed: z.string().optional(),
    brightWhite: z.string().optional(),
    brightYellow: z.string().optional(),
    cursor: z.string().optional(),
    cursorAccent: z.string().optional(),
    cyan: z.string().optional(),
    foreground: z.string().optional(),
    green: z.string().optional(),
    magenta: z.string().optional(),
    red: z.string().optional(),
    selectionBackground: z.string().optional(),
    selectionForeground: z.string().optional(),
    selectionInactiveBackground: z.string().optional(),
    white: z.string().optional(),
    yellow: z.string().optional()
  })
  .optional()

const terminalSettingsInput = z.object({
  bellStyle: z.enum(['none', 'sound', 'visual', 'both']).optional(),
  cursorBlink: z.boolean().optional(),
  cursorInactiveStyle: z.enum(['outline', 'block', 'bar', 'underline', 'none']).optional(),
  cursorStyle: z.enum(['block', 'underline', 'bar']).optional(),
  fontFamily: z.string().optional(),
  fontSize: z.number().int().min(8).max(72).optional(),
  letterSpacing: z.number().min(-5).max(10).optional(),
  lineHeight: z.number().min(1.0).max(2.0).optional(),
  scrollback: z.number().int().min(100).max(100_000).optional(),
  themeName: z.string().optional(),
  themeOverrides: themeOverridesSchema
})

export const terminalSettingsRouter = {
  get: protectedProcedure.handler(async ({ context }) => {
    const rows = await db.select().from(terminalSettings).where(eq(terminalSettings.userId, context.session.user.id))
    if (rows.length === 0) {
      return { global: DEFAULT_GLOBAL, hostOverrides: {} }
    }
    const row = rows[0]
    const rawGlobal = row.settingsJson
    const globalData = rawGlobal && typeof rawGlobal === 'object' && !Array.isArray(rawGlobal) ? rawGlobal : {}
    const rawOverrides = row.hostOverridesJson
    const overridesData =
      rawOverrides && typeof rawOverrides === 'object' && !Array.isArray(rawOverrides) ? rawOverrides : {}
    return {
      global: {
        ...DEFAULT_GLOBAL,
        ...globalData
      },
      hostOverrides: overridesData as Record<string, Record<string, unknown>>
    }
  }),

  upsert: protectedProcedure
    .input(
      z.object({
        global: terminalSettingsInput.optional(),
        hostOverrides: z.record(z.string(), terminalSettingsInput).optional()
      })
    )
    .handler(async ({ input, context }) => {
      const userId = context.session.user.id

      const existing = await db.select().from(terminalSettings).where(eq(terminalSettings.userId, userId))

      const rawGlobal = existing.length > 0 ? existing[0].settingsJson : null
      const currentGlobal =
        rawGlobal && typeof rawGlobal === 'object' && !Array.isArray(rawGlobal)
          ? (rawGlobal as Record<string, unknown>)
          : {}
      const rawOverrides = existing.length > 0 ? existing[0].hostOverridesJson : null
      const currentOverrides =
        rawOverrides && typeof rawOverrides === 'object' && !Array.isArray(rawOverrides)
          ? (rawOverrides as Record<string, Record<string, unknown>>)
          : {}

      const mergedGlobal = input.global ? { ...currentGlobal, ...input.global } : currentGlobal
      const mergedOverrides: Record<string, unknown> = {
        ...currentOverrides
      }
      if (input.hostOverrides) {
        for (const [hostId, overrideValues] of Object.entries(input.hostOverrides)) {
          const prev = (mergedOverrides[hostId] as Record<string, unknown>) ?? {}
          mergedOverrides[hostId] = { ...prev, ...overrideValues }
        }
      }

      await db
        .insert(terminalSettings)
        .values({
          userId,
          settingsJson: mergedGlobal,
          hostOverridesJson: mergedOverrides
        })
        .onConflictDoUpdate({
          target: terminalSettings.userId,
          set: {
            settingsJson: mergedGlobal,
            hostOverridesJson: mergedOverrides
          }
        })

      return { success: true }
    }),

  deleteHostOverride: protectedProcedure.input(z.object({ hostId: z.string() })).handler(async ({ input, context }) => {
    const userId = context.session.user.id

    const existing = await db.select().from(terminalSettings).where(eq(terminalSettings.userId, userId))

    if (existing.length === 0) {
      return { success: true }
    }

    const rawOverrides = existing[0].hostOverridesJson
    const overrides: Record<string, unknown> = {
      ...(rawOverrides && typeof rawOverrides === 'object' && !Array.isArray(rawOverrides) ? rawOverrides : {})
    }
    delete overrides[input.hostId]

    await db.update(terminalSettings).set({ hostOverridesJson: overrides }).where(eq(terminalSettings.userId, userId))

    return { success: true }
  })
}
