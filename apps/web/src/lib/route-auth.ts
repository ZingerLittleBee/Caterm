import { redirect } from '@tanstack/react-router'

import { authClient } from '@/lib/auth-client'

export interface SessionGatePayload {
  data: unknown | null
  error?: { message?: string } | null
}

export class SessionVerificationError extends Error {
  constructor(message = 'Failed to verify your session. Retry to continue.') {
    super(message)
    this.name = 'SessionVerificationError'
  }
}

export function getSessionGateOutcome(payload: SessionGatePayload): 'authenticated' | 'redirect' | 'error' {
  if (payload.error) {
    return 'error'
  }

  if (!payload.data) {
    return 'redirect'
  }

  return 'authenticated'
}

export async function requireAuthenticatedSession() {
  const result = await authClient.getSession()
  const outcome = getSessionGateOutcome(result)

  if (outcome === 'error') {
    throw new SessionVerificationError(result.error?.message ?? undefined)
  }

  if (outcome === 'redirect') {
    throw redirect({ to: '/login' })
  }

  return result.data
}
