const INVALID_CREDENTIALS_STATUS = 401
const INVALID_CREDENTIALS_CODE = 'INVALID_EMAIL_OR_PASSWORD'
const SIGN_IN_RETRY_MESSAGE = 'Unable to sign in right now. Check your connection and try again.'

interface AuthClientErrorLike {
  code?: string
  message?: string
  status: number
  statusText: string
}

export interface SignInErrorLike {
  error: AuthClientErrorLike
}

export function getSignInErrorMessage(result: SignInErrorLike): string {
  const { code, message, status, statusText } = result.error

  if (status === INVALID_CREDENTIALS_STATUS || code === INVALID_CREDENTIALS_CODE) {
    return 'Invalid email or password'
  }

  if (status >= 500 || status <= 0) {
    return SIGN_IN_RETRY_MESSAGE
  }

  return message || statusText || SIGN_IN_RETRY_MESSAGE
}
