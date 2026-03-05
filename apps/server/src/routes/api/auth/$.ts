import { auth } from '@Caterm/auth'
import { addCorsHeaders } from '../../../lib/cors'
import { createFileRoute } from '@tanstack/react-router'

async function handle({ request }: { request: Request }) {
  if (request.method === 'OPTIONS') {
    return addCorsHeaders(new Response(null, { status: 204 }), request)
  }
  const response = await auth.handler(request)
  return addCorsHeaders(response, request)
}

export const Route = createFileRoute('/api/auth/$')({
  server: {
    handlers: {
      OPTIONS: handle,
      GET: handle,
      POST: handle
    }
  }
})
