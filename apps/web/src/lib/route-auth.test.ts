// @ts-expect-error bun:test is available at runtime in Bun but not declared in this web tsconfig
import { expect, test } from 'bun:test'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'

import { SessionRouteError } from '@/components/auth/session-route-error'
import { getSessionGateOutcome } from './route-auth'
import { SessionVerificationError } from './route-auth'

test('getSessionGateOutcome returns redirect when there is no session data', () => {
  expect(getSessionGateOutcome({ data: null, error: null })).toBe('redirect')
})

test('getSessionGateOutcome returns error when verification fails', () => {
  expect(getSessionGateOutcome({ data: null, error: { message: 'network-down' } })).toBe('error')
})

test('getSessionGateOutcome returns authenticated when session data exists', () => {
  expect(getSessionGateOutcome({ data: { user: { id: 'u_1' } }, error: null })).toBe('authenticated')
})

test('SessionRouteError renders the verification-failure UI for SessionVerificationError', () => {
  const markup = renderToStaticMarkup(
    createElement(SessionRouteError, { error: new SessionVerificationError('network-down') })
  )

  expect(markup).toContain('Session verification failed')
  expect(markup).toContain('network-down')
  expect(markup).toContain('Retry')
})

test('SessionRouteError rethrows non-session errors', () => {
  expect(() => SessionRouteError({ error: new Error('boom') })).toThrow('boom')
})
