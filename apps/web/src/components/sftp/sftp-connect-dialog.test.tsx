// @ts-expect-error bun:test is available at runtime in Bun but not declared in this web tsconfig
import { expect, mock, test } from 'bun:test'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'

const reactQuery = await import('@tanstack/react-query')

const useQuery = mock(() => ({
  data: [],
  isError: true,
  isLoading: false
}))

mock.module('@tanstack/react-query', () => ({
  ...reactQuery,
  useQuery
}))

const { SftpHostListContent } = await import('./sftp-connect-dialog')

test('SftpHostListContent shows host sync error UI instead of the empty state', () => {
  const markup = renderToStaticMarkup(
    createElement(SftpHostListContent, {
      connecting: null,
      isError: true,
      hosts: [],
      isLoading: false,
      onRetry: () => undefined,
      onSelectHost: () => undefined
    })
  )

  expect(markup).toContain('SSH hosts unavailable')
  expect(markup).toContain('Retry')
  expect(markup).not.toContain('No hosts configured. Add a host from the SSH page first.')
})
