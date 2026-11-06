import viteConfig from '../../vite.config'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { assertDeploymentFlags, assertStagingOrigin, stagingBrowserContainment } from '../../build/staging'

describe('deployment build contract', () => {
  it.each(['stagng', 'Staging', ' production', 'staging ', ' ', 'PRODUCTION'])('rejects nonempty typo %j in either flag', value => {
    expect(() => assertDeploymentFlags({ DEPLOYMENT_ENV: value }, 'test')).toThrow()
    expect(() => assertDeploymentFlags({ VITE_DEPLOYMENT_ENV: value }, 'test')).toThrow()
  })
  it.each([{}, { DEPLOYMENT_ENV: 'staging' }, { VITE_DEPLOYMENT_ENV: 'staging' }, { DEPLOYMENT_ENV: 'production', VITE_DEPLOYMENT_ENV: 'staging' }])('rejects missing or mismatched production build flags %j', env => {
    expect(() => assertDeploymentFlags(env, 'production')).toThrow()
  })
  it('allows explicit matched flags and absent dev/test flags', () => {
    for (const value of ['production', 'staging']) expect(() => assertDeploymentFlags({ DEPLOYMENT_ENV: value, VITE_DEPLOYMENT_ENV: value }, 'production')).not.toThrow()
    expect(() => assertDeploymentFlags({}, 'test')).not.toThrow()
    expect(() => assertDeploymentFlags({}, 'development')).not.toThrow()
    expect(() => assertDeploymentFlags({ DEPLOYMENT_ENV: 'test', VITE_DEPLOYMENT_ENV: 'development' }, 'test')).toThrow()
  })
})

describe('staging font containment', () => {
  const plugin = stagingBrowserContainment(true)
  it.each([
    '@import url("https://fonts.googleapis.com/css2?family=Inter");',
    "@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&display=swap');",
    "@import 'https://fonts.gstatic.com/font.css';",
    '@import url(https://fonts.googleapis.com/css2?family=Inter) screen;',
    '@import\n url(\n "https://fonts.googleapis.com/css2?family=Inter"\n);',
    '@import "//fonts.googleapis.com/css2?family=Inter";',
  ])('removes alternate import %s with a normalized CSS module id', css => {
    expect(plugin.transform(`${css}\n.keep { color: red; }`, 'C:\\repo\\src\\other.css?direct')).toBe('\n.keep { color: red; }')
  })
  it('removes font links and rejects surviving emitted CSS, HTML and JS URLs', () => {
    expect(plugin.transformIndexHtml('<link rel="preconnect" href="https://fonts.gstatic.com"><p>safe</p>')).toBe('<p>safe</p>')
    for (const name of ['app.css', 'index.html', 'app.js']) {
      expect(() => plugin.generateBundle({}, { [name]: { type: 'asset', source: new TextEncoder().encode('https://fonts.gstatic.com/font') } })).toThrow(/external font URL/)
      expect(() => plugin.generateBundle({}, { [name]: { type: 'chunk', code: 'https://fonts.googleapis.com/css' } })).toThrow(/external font URL/)
    }
    expect(() => plugin.generateBundle({}, { 'app.css': { type: 'asset', source: 'body { color: red }' } })).not.toThrow()
  })
  it('preserves production imports and links', () => {
    const production = stagingBrowserContainment(false)
    const css = '@import "https://fonts.googleapis.com/css";'
    expect(production.transform(css, '/src/index.css')).toBeUndefined()
    expect(production.transformIndexHtml(css)).toBe(css)
    expect(() => production.generateBundle({}, { 'app.css': { type: 'asset', source: css } })).not.toThrow()
  })
})

it('requires exact staging browser origins for the peer build setting', () => {
  expect(() => assertStagingOrigin('https://peer-staging.example.test', 'PEER')).not.toThrow()
  for (const origin of [undefined, 'https://app.aireservicesguam.com', 'https://aire-services-guam.netlify.app', 'https://PEER-STAGING.example.test', 'https://peer-staging.example.test/', 'https://peer-staging.example.test:443', 'http://peer-staging.example.test', 'https://user@peer-staging.example.test', 'https://peer-staging.example.test?foo=1']) {
    expect(() => assertStagingOrigin(origin, 'PEER')).toThrow()
  }
})

afterEach(() => vi.unstubAllEnvs())
it('enforces peer origin and snapshot contracts even for --mode test builds', () => {
  const env: Record<string, string> = { DEPLOYMENT_ENV: 'staging', VITE_DEPLOYMENT_ENV: 'staging', VITE_STAGING_SNAPSHOT_AT: '2026-10-24T00:00:00Z', VITE_STAGING_CODE_SHA: 'a'.repeat(40), VITE_API_URL: 'https://api-staging.example.test', VITE_CLERK_PUBLISHABLE_KEY: 'pk_test_synthetic', VITE_AUTH_ENABLED: 'true', VITE_STAGING_AIRE_FRONTEND_ORIGIN: 'https://peer-staging.example.test' }
  for (const [key, value] of Object.entries(env)) vi.stubEnv(key, value)
  const build = (): unknown => (viteConfig as (config: { mode: string; command: 'build' }) => unknown)({ mode: 'test', command: 'build' })
  expect(build).not.toThrow()
  for (const key of ['VITE_STAGING_AIRE_FRONTEND_ORIGIN', 'VITE_STAGING_SNAPSHOT_AT', 'VITE_STAGING_CODE_SHA']) {
    vi.stubEnv(key, '')
    expect(build).toThrow()
    vi.stubEnv(key, env[key])
  }
})
