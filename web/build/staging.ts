type BuildEnvironment = Record<string, string | undefined>
type EmittedFile = { type: 'asset'; source: string | Uint8Array } | { type: 'chunk'; code: string }

export function assertDeploymentFlags(env: BuildEnvironment, mode: string): void {
  const allowed = ['staging', 'production', 'local', 'development', 'test']
  for (const key of ['DEPLOYMENT_ENV', 'VITE_DEPLOYMENT_ENV']) {
    if (env[key] && !allowed.includes(env[key])) throw new Error(`Invalid ${key}: use an exact supported deployment environment`)
  }
  const backend = env.DEPLOYMENT_ENV || ''
  const frontend = env.VITE_DEPLOYMENT_ENV || ''
  if (backend !== frontend) throw new Error('DEPLOYMENT_ENV and VITE_DEPLOYMENT_ENV must explicitly match')
  if (mode === 'production' && !['staging', 'production', 'local'].includes(frontend)) {
    throw new Error('Production-mode builds require explicit matching production, staging or local deployment flags')
  }
}

const HOSTED_MARKERS = ['NETLIFY', 'CI', 'GITHUB_ACTIONS', 'RENDER', 'RENDER_SERVICE_ID']

// A local production copy (ops/local-prod) builds on a developer machine only,
// with a Clerk development key and *.localhost origins.
export function assertLocalBuild(env: BuildEnvironment): void {
  const hosted = HOSTED_MARKERS.filter(key => env[key]?.trim())
  if (hosted.length) throw new Error(`Local builds are refused on a hosted platform or CI (${hosted.join(', ')})`)
  const live = Object.keys(env).filter(key => /^(?:sk|pk)_live_/.test(env[key]?.trim() || '')).sort()
  if (live.length) throw new Error(`Local builds are refused with live keys (${live.join(', ')})`)
  if (!env.VITE_CLERK_PUBLISHABLE_KEY?.startsWith('pk_test_')) throw new Error('Local build requires a Clerk development VITE_CLERK_PUBLISHABLE_KEY (pk_test_)')
  const root = env.VITE_TENANT_ROOT_DOMAIN || ''
  if (!/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+localhost$/.test(root)) throw new Error('Local build requires VITE_TENANT_ROOT_DOMAIN under .localhost')
  let api: URL
  try { api = new URL(env.VITE_API_URL || '') } catch { throw new Error('Local build requires VITE_API_URL') }
  if (api.protocol !== 'https:' || api.username || api.password || !(api.hostname === root || api.hostname.endsWith(`.${root}`))) {
    throw new Error('Local build requires an HTTPS VITE_API_URL under VITE_TENANT_ROOT_DOMAIN')
  }
  if (env.VITE_AUTH_ENABLED === 'false') throw new Error('Local build requires authentication')
  if (env.VITE_PUBLIC_POSTHOG_ENABLED === 'true') throw new Error('Local build must not enable PostHog')
}

export function assertStagingOrigin(value: string | undefined, key: string): void {
  let url: URL
  try { url = new URL(value || '') } catch { throw new Error(`Staging build requires ${key}`) }
  if (url.protocol !== 'https:' || value !== url.origin || url.port ||
      !/(?:^|[.-])staging(?:[.-]|$)/.test(url.hostname)) {
    throw new Error(`${key} must be an exact HTTPS staging origin`)
  }
}

export function stagingBrowserContainment(staging: boolean) {
  return {
    name: 'staging-browser-containment',
    enforce: 'pre' as const,
    transform(code: string, id: string): string | undefined {
      const normalized = id.split(/[?#]/)[0].replace(/\\/g, '/')
      if (!staging || !normalized.endsWith('.css')) return
      return code.replace(/@import\s+(?:url\(\s*(?:'[^']*'|"[^"]*"|[^)\s]+)\s*\)|'[^']*'|"[^"]*")[^;]*(?:;|$)/gi,
        statement => /(?:https?:)?\/\/fonts\.(?:googleapis|gstatic)\.com(?:[/:]|$)/i.test(statement) ? '' : statement)
    },
    transformIndexHtml(html: string): string {
      if (!staging) return html
      return html.replace(/<link\b[^>]*(?:fonts\.googleapis\.com|fonts\.gstatic\.com)[^>]*>/gi, '')
    },
    generateBundle(_options: unknown, bundle: Record<string, EmittedFile>): void {
      if (!staging) return
      for (const [name, item] of Object.entries(bundle)) {
        const text = item.type === 'chunk' ? item.code : typeof item.source === 'string' ? item.source : new TextDecoder().decode(item.source)
        if (/fonts\.(?:googleapis|gstatic)\.com/i.test(text)) throw new Error(`Staging build contains an external font URL in ${name}`)
      }
    },
  }
}
