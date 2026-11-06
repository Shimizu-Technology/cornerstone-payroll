type BuildEnvironment = Record<string, string | undefined>
type EmittedFile = { type: 'asset'; source: string | Uint8Array } | { type: 'chunk'; code: string }

export function assertDeploymentFlags(env: BuildEnvironment, mode: string): void {
  const allowed = ['staging', 'production', 'development', 'test']
  for (const key of ['DEPLOYMENT_ENV', 'VITE_DEPLOYMENT_ENV']) {
    if (env[key] && !allowed.includes(env[key])) throw new Error(`Invalid ${key}: use an exact supported deployment environment`)
  }
  const backend = env.DEPLOYMENT_ENV || ''
  const frontend = env.VITE_DEPLOYMENT_ENV || ''
  if (backend !== frontend) throw new Error('DEPLOYMENT_ENV and VITE_DEPLOYMENT_ENV must explicitly match')
  if (mode === 'production' && !['staging', 'production'].includes(frontend)) {
    throw new Error('Production-mode builds require explicit matching production or staging deployment flags')
  }
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
