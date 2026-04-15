// @ts-expect-error bun:test is available at runtime in Bun but not declared in this web tsconfig
import { expect, mock, test } from 'bun:test'
import { createElement, type ReactNode } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'

const reactQuery = await import('@tanstack/react-query')

const useQuery = mock(() => ({
  data: [],
  isError: true,
  isPending: false,
  refetch: () => Promise.resolve()
}))

mock.module('@base-ui/react/dialog', () => ({
  Dialog: {
    Backdrop: () => null,
    Close: ({ render }: { render: ReactNode }) => render,
    Description: ({ children }: { children: ReactNode }) => children,
    Popup: ({ children }: { children: ReactNode }) => children,
    Portal: ({ children }: { children: ReactNode }) => children,
    Root: ({ children }: { children: ReactNode }) => children,
    Title: ({ children }: { children: ReactNode }) => children
  }
}))

mock.module('@tanstack/react-query', () => ({
  ...reactQuery,
  useQuery
}))

const { SftpConnectDialog } = await import('./sftp-connect-dialog')

test('SftpConnectDialog shows host sync error UI instead of the empty state', () => {
  const markup = renderToStaticMarkup(
    createElement(SftpConnectDialog, {
      onClose: () => undefined,
      onConnect: () => undefined,
      open: true,
      openStandalone: async () => 'session_1'
    })
  )

  expect(markup).toContain('SSH hosts unavailable')
  expect(markup).toContain('>Retry<')
  expect(markup).not.toContain('No hosts configured. Add a host from the SSH page first.')
})
