// @ts-expect-error bun:test is available at runtime in Bun but not declared in this web tsconfig
import { afterEach, expect, mock, test } from 'bun:test'

let sessionResult: { data: unknown | null; error: { message?: string } | null } = {
  data: null,
  error: null
}

const getSession = mock(async () => sessionResult)

mock.module('@/lib/auth-client', () => ({
  authClient: {
    getSession
  }
}))

const { requireAuthenticatedSession, SessionVerificationError } = await import('./route-auth')

afterEach(() => {
  sessionResult = { data: null, error: null }
})

test('requireAuthenticatedSession throws redirect when there is no session', async () => {
  sessionResult = { data: null, error: null }

  try {
    await requireAuthenticatedSession()
    throw new Error('Expected redirect to be thrown.')
  } catch (error) {
    expect(error).toBeInstanceOf(Response)
    expect((error as { options?: { to?: string } }).options?.to).toBe('/login')
  }
})

test('requireAuthenticatedSession throws SessionVerificationError when authClient.getSession reports an error', async () => {
  sessionResult = { data: null, error: { message: 'network-down' } }

  try {
    await requireAuthenticatedSession()
    throw new Error('Expected session verification error to be thrown.')
  } catch (error) {
    expect(error).toBeInstanceOf(SessionVerificationError)
    expect(error).toHaveProperty('message', 'network-down')
  }
})

test('requireAuthenticatedSession returns session data when authenticated', async () => {
  const session = { user: { id: 'u_1' } }
  sessionResult = { data: session, error: null }

  await expect(requireAuthenticatedSession()).resolves.toBe(session)
})
