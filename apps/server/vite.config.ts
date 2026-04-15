import tailwindcss from '@tailwindcss/vite'
import { tanstackStart } from '@tanstack/react-start/plugin/vite'
import viteReact from '@vitejs/plugin-react'
import { defineConfig } from 'vite'
import tsconfigPaths from 'vite-tsconfig-paths'

export default defineConfig({
  plugins: [tsconfigPaths(), tailwindcss(), tanstackStart(), viteReact()],
  server: {
    port: 3002,
    cors: {
      origin: ['http://localhost:3001', 'https://tauri.localhost', 'tauri://localhost'],
      credentials: true
    }
  },
  ssr: {
    noExternal: ['@t3-oss/env-core'],
    external: ['pg', 'pg-protocol']
  },
  optimizeDeps: {
    exclude: ['pg', 'pg-protocol']
  },
  build: {
    commonjsOptions: {
      transformMixedEsModules: true
    }
  }
})
