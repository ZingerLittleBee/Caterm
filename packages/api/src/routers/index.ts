import type { RouterClient } from '@orpc/server'

import { protectedProcedure, publicProcedure } from '../index'
import { sftpBookmarkRouter } from './sftp-bookmark'
import { sshHostRouter } from './ssh-host'
import { terminalSettingsRouter } from './terminal-settings'
import { todoRouter } from './todo'

export const appRouter = {
  healthCheck: publicProcedure.handler(() => {
    return 'OK'
  }),
  privateData: protectedProcedure.handler(({ context }) => {
    return {
      message: 'This is private',
      user: context.session?.user
    }
  }),
  sftpBookmark: sftpBookmarkRouter,
  sshHost: sshHostRouter,
  terminalSettings: terminalSettingsRouter,
  todo: todoRouter
}
export type AppRouter = typeof appRouter
export type AppRouterClient = RouterClient<typeof appRouter>
