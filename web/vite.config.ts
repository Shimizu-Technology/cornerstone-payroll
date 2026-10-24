import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import path from 'path'

// https://vite.dev/config/
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  if (env.DEPLOYMENT_ENV === 'staging' && env.VITE_DEPLOYMENT_ENV !== 'staging') throw new Error('DEPLOYMENT_ENV=staging requires VITE_DEPLOYMENT_ENV=staging')
  if (env.VITE_DEPLOYMENT_ENV === 'staging' && mode !== 'test') {
    for (const key of ['VITE_STAGING_SNAPSHOT_AT', 'VITE_STAGING_CODE_SHA', 'VITE_API_URL', 'VITE_CLERK_PUBLISHABLE_KEY']) {
      if (!env[key]) throw new Error(`Staging build requires ${key}`)
    }
    const api = new URL(env.VITE_API_URL)
    if (api.protocol !== 'https:' || api.port || api.username || api.password || !/(?:^|[.-])staging(?:[.-]|$)/.test(api.hostname)) {
      throw new Error('Staging build requires an explicit HTTPS staging API hostname')
    }
    if (!/^[0-9a-f]{40}$/.test(env.VITE_STAGING_CODE_SHA)) throw new Error('VITE_STAGING_CODE_SHA must be a full commit SHA')
    if (Number.isNaN(Date.parse(env.VITE_STAGING_SNAPSHOT_AT))) throw new Error('VITE_STAGING_SNAPSHOT_AT must be a recorded timestamp')
    if (!env.VITE_CLERK_PUBLISHABLE_KEY.startsWith('pk_test_')) throw new Error('Staging build requires a separate test Clerk instance')
    if (env.VITE_AUTH_ENABLED === 'false') throw new Error('Staging build requires authentication')
  }
  return {
  plugins: [{
    name: 'staging-browser-containment',
    enforce: 'pre' as const,
    transform(code: string, id: string) {
      if (env.VITE_DEPLOYMENT_ENV !== 'staging' || !id.endsWith('/src/index.css')) return
      return code.replace(/^@import url\(['"]https:\/\/fonts\.googleapis\.com[^\n]+\n/m, '')
    },
    transformIndexHtml(html: string) {
      if (env.VITE_DEPLOYMENT_ENV !== 'staging') return html
      return html.replace(/<link[^>]+(?:fonts\.googleapis\.com|fonts\.gstatic\.com)[^>]*>/g, '')
    },
  }, react(), tailwindcss()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
}
})
