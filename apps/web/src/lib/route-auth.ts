import { redirect } from '@tanstack/react-router'

import { authClient } from '@/lib/auth-client'

export type SessionResult = Awaited<ReturnType<typeof authClient.getSession>>
export type AuthenticatedSession = NonNullable<SessionResult['data']>

export class SessionVerificationError extends Error {
  constructor(message = 'Failed to verify your session. Retry to continue.') {
    super(message)
    this.name = 'SessionVerificationError'
  }
}

export function getSessionGateOutcome(payload: SessionResult): 'authenticated' | 'redirect' | 'error' {
  if (payload.error) {
    return 'error'
  }

  if (!payload.data) {
    return 'redirect'
  }

  return 'authenticated'
}

export async function requireAuthenticatedSession(): Promise<AuthenticatedSession> {
  const result = await authClient.getSession()
  const outcome = getSessionGateOutcome(result)

  if (outcome === 'error') {
    throw new SessionVerificationError(result.error?.message ?? undefined)
  }

  if (outcome === 'redirect') {
    throw redirect({ to: '/login' })
  }

  const session = result.data

  if (!session) {
    throw new Error('Session gate invariant violated.')
  }

  return session
}
