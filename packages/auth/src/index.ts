import { db } from '@Caterm/db'
import * as schema from '@Caterm/db/schema/auth'
import { env } from '@Caterm/env/server'
import { betterAuth } from 'better-auth'
import { drizzleAdapter } from 'better-auth/adapters/drizzle'
import { tanstackStartCookies } from 'better-auth/tanstack-start'

export const auth = betterAuth({
  database: drizzleAdapter(db, {
    provider: 'pg',

    schema
  }),
  trustedOrigins: [env.CORS_ORIGIN],
  emailAndPassword: {
    enabled: true
  },
  plugins: [tanstackStartCookies()]
})
