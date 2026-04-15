// @ts-expect-error bun:test is available at runtime in Bun but not declared in this web tsconfig
import { expect, test } from 'bun:test'

import { getSessionGateOutcome } from './route-auth'

test('getSessionGateOutcome returns redirect when there is no session data', () => {
  expect(getSessionGateOutcome({ data: null, error: null })).toBe('redirect')
})

test('getSessionGateOutcome returns error when verification fails', () => {
  expect(getSessionGateOutcome({ data: null, error: { message: 'network-down' } })).toBe('error')
})

test('getSessionGateOutcome returns authenticated when session data exists', () => {
  expect(getSessionGateOutcome({ data: { user: { id: 'u_1' } }, error: null })).toBe('authenticated')
})
