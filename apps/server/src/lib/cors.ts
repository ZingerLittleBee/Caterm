import { env } from '@Caterm/env/server'

function isAllowedOrigin(origin: string): boolean {
  if (origin === env.CORS_ORIGIN) {
    return true
  }
  if (origin === 'https://tauri.localhost') {
    return true
  }
  if (origin === 'tauri://localhost') {
    return true
  }
  return false
}

export function addCorsHeaders(response: Response, request: Request): Response {
  const origin = request.headers.get('origin')
  if (!(origin && isAllowedOrigin(origin))) {
    return response
  }
  const headers = new Headers(response.headers)
  headers.set('Access-Control-Allow-Origin', origin)
  headers.set('Access-Control-Allow-Credentials', 'true')
  headers.set('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD')
  headers.set('Access-Control-Allow-Headers', 'Content-Type, Authorization')
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers
  })
}
