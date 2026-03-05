import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'

import { SignInForm } from '@/components/sign-in-form'
import { SignUpForm } from '@/components/sign-up-form'

export const Route = createFileRoute('/login')({
  component: LoginPage
})

function LoginPage() {
  const [isSignUp, setIsSignUp] = useState(false)

  return isSignUp ? (
    <SignUpForm onSwitchToSignIn={() => setIsSignUp(false)} />
  ) : (
    <SignInForm onSwitchToSignUp={() => setIsSignUp(true)} />
  )
}
