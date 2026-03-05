import { createContext } from '@Caterm/api/context'
import { appRouter } from '@Caterm/api/routers/index'
import { env } from '@Caterm/env/server'
import { OpenAPIHandler } from '@orpc/openapi/fetch'
import { OpenAPIReferencePlugin } from '@orpc/openapi/plugins'
import { onError } from '@orpc/server'
import { RPCHandler } from '@orpc/server/fetch'
import { ZodToJsonSchemaConverter } from '@orpc/zod/zod4'
import { createFileRoute } from '@tanstack/react-router'

const rpcHandler = new RPCHandler(appRouter, {
  interceptors: [
    onError((error) => {
      console.error(error)
    })
  ]
})

const apiHandler = new OpenAPIHandler(appRouter, {
  plugins: [
    new OpenAPIReferencePlugin({
      schemaConverters: [new ZodToJsonSchemaConverter()]
    })
  ],
  interceptors: [
    onError((error) => {
      console.error(error)
    })
  ]
})

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

function addCorsHeaders(response: Response, request: Request): Response {
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

async function handle({ request }: { request: Request }) {
  if (request.method === 'OPTIONS') {
    return addCorsHeaders(new Response(null, { status: 204 }), request)
  }

  const rpcResult = await rpcHandler.handle(request, {
    prefix: '/api/rpc',
    context: await createContext({ req: request })
  })
  if (rpcResult.response) {
    return addCorsHeaders(rpcResult.response, request)
  }

  const apiResult = await apiHandler.handle(request, {
    prefix: '/api/rpc/api-reference',
    context: await createContext({ req: request })
  })
  if (apiResult.response) {
    return addCorsHeaders(apiResult.response, request)
  }

  return addCorsHeaders(new Response('Not found', { status: 404 }), request)
}

export const Route = createFileRoute('/api/rpc/$')({
  server: {
    handlers: {
      OPTIONS: handle,
      HEAD: handle,
      GET: handle,
      POST: handle,
      PUT: handle,
      PATCH: handle,
      DELETE: handle
    }
  }
})
