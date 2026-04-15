// @ts-expect-error bun:test is available at runtime in Bun but not declared in this web tsconfig
import { expect, test } from 'bun:test'

import { getSignInErrorMessage } from './auth-error-message'

test('getSignInErrorMessage returns invalid credentials copy for 401 responses', () => {
  expect(
    getSignInErrorMessage({
      error: {
        status: 401,
        statusText: 'Unauthorized'
      }
    })
  ).toBe('Invalid email or password')
})

test('getSignInErrorMessage returns invalid credentials copy for invalid-email-or-password code', () => {
  expect(
    getSignInErrorMessage({
      error: {
        code: 'INVALID_EMAIL_OR_PASSWORD',
        message: 'Email or password is incorrect',
        status: 400,
        statusText: 'Bad Request'
      }
    })
  ).toBe('Invalid email or password')
})

test('getSignInErrorMessage returns network/server copy for server errors', () => {
  expect(
    getSignInErrorMessage({
      error: {
        message: 'Database unavailable',
        status: 503,
        statusText: 'Service Unavailable'
      }
    })
  ).toBe('Unable to sign in right now. Check your connection and try again.')
})

test('getSignInErrorMessage preserves specific non-auth validation messages', () => {
  expect(
    getSignInErrorMessage({
      error: {
        message: 'Email is not verified',
        status: 403,
        statusText: 'Forbidden'
      }
    })
  ).toBe('Email is not verified')
})
