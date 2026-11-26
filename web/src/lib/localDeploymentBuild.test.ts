import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import viteConfig from '../../vite.config'
import { assertDeploymentFlags, assertLocalBuild } from '../../build/staging'
import { finalizeEmployeeDist, finalizeStaffDist, posthogOrigins } from '../../scripts/finalize-surface-dist.mjs'
import { shouldEnableAnalytics } from './analytics'
import { clientSubdomainHost, DEFAULT_TENANT_ROOT_DOMAIN, tenantRootDomain } from './tenant-subdomain'

const publishableKey = (host: string, prefix: string): string => `${prefix}${Buffer.from(`${host}$`).toString('base64')}`
const devKey = publishableKey('example-local-1.clerk.accounts.dev', 'pk_test_')
const localBuild = {
  DEPLOYMENT_ENV: 'local',
  VITE_DEPLOYMENT_ENV: 'local',
  VITE_CLERK_PUBLISHABLE_KEY: devKey,
  VITE_TENANT_ROOT_DOMAIN: 'cornerstone.localhost',
  VITE_API_URL: 'https://api.cornerstone.localhost:8443/api/v1',
}

describe('local production copy build', () => {
  it('accepts matched local flags for a production-mode build', () => {
    expect(() => assertDeploymentFlags(localBuild, 'production')).not.toThrow()
    expect(() => assertDeploymentFlags({ DEPLOYMENT_ENV: 'local', VITE_DEPLOYMENT_ENV: 'production' }, 'production')).toThrow()
    expect(() => assertLocalBuild(localBuild)).not.toThrow()
  })

  it.each(['NETLIFY', 'CI', 'GITHUB_ACTIONS', 'RENDER'])('refuses to build on %s', marker => {
    expect(() => assertLocalBuild({ ...localBuild, [marker]: 'true' })).toThrow(/hosted platform or CI/)
  })

  it('refuses live keys, a hosted API and PostHog', () => {
    expect(() => assertLocalBuild({ ...localBuild, VITE_CLERK_PUBLISHABLE_KEY: 'pk_live_x' })).toThrow(/live keys/)
    expect(() => assertLocalBuild({ ...localBuild, OTHER: 'sk_live_x' })).toThrow(/live keys \(OTHER\)/)
    expect(() => assertLocalBuild({ ...localBuild, VITE_API_URL: 'https://cornerstone-payroll.onrender.com/api/v1' })).toThrow(/VITE_API_URL/)
    expect(() => assertLocalBuild({ ...localBuild, VITE_TENANT_ROOT_DOMAIN: 'shimizu-technology.com' })).toThrow(/VITE_TENANT_ROOT_DOMAIN/)
    expect(() => assertLocalBuild({ ...localBuild, VITE_PUBLIC_POSTHOG_ENABLED: 'true' })).toThrow(/PostHog/)
    expect(() => assertLocalBuild({ ...localBuild, VITE_AUTH_ENABLED: 'false' })).toThrow(/authentication/)
  })

  it('serves tenants under the local root domain only in a local build', () => {
    expect(tenantRootDomain(localBuild)).toBe('cornerstone.localhost')
    expect(tenantRootDomain({ ...localBuild, VITE_DEPLOYMENT_ENV: 'production' })).toBe(DEFAULT_TENANT_ROOT_DOMAIN)
    expect(tenantRootDomain({ ...localBuild, VITE_TENANT_ROOT_DOMAIN: 'evil.example.com' })).toBe(DEFAULT_TENANT_ROOT_DOMAIN)
    expect(clientSubdomainHost({ hostname: 'harborfinch.cornerstone.localhost', search: '' }, false, 'cornerstone.localhost'))
      .toBe('harborfinch.cornerstone.localhost')
    expect(clientSubdomainHost({ hostname: 'payroll.cornerstone.localhost', search: '' }, false, 'cornerstone.localhost')).toBeNull()
    expect(clientSubdomainHost({ hostname: 'employee-api.cornerstone.localhost', search: '' }, false, 'cornerstone.localhost')).toBeNull()
    expect(clientSubdomainHost({ hostname: 'harborfinch.cornerstone.localhost', search: '' })).toBeNull()
  })

  it('keeps PostHog off', () => {
    const enabled = { VITE_PUBLIC_POSTHOG_ENABLED: 'true', VITE_PUBLIC_POSTHOG_KEY: 'phc_test' }
    expect(posthogOrigins({ ...enabled, VITE_DEPLOYMENT_ENV: 'local' })).toBeNull()
    expect(shouldEnableAnalytics({ env: { ...enabled, VITE_DEPLOYMENT_ENV: 'local' }, isStagingEnv: false, hasSupportToken: false, navigatorObj: {}, windowObj: {} })).toBe(false)
    expect(shouldEnableAnalytics({ env: { ...enabled, VITE_DEPLOYMENT_ENV: 'production' }, isStagingEnv: false, hasSupportToken: false, navigatorObj: {}, windowObj: {} })).toBe(true)
  })
})

describe('local build wiring', () => {
  const webDir = path.resolve(__dirname, '../..')
  const dirs: string[] = []
  const dist = (): string => {
    const dir = mkdtempSync(path.join(tmpdir(), 'local-dist-'))
    dirs.push(dir)
    writeFileSync(path.join(dir, 'index.html'), '<html></html>')
    return dir
  }
  const build = (): unknown => (viteConfig as (config: { mode: string; command: 'build' }) => unknown)({ mode: 'production', command: 'build' })
  const stubLocal = (overrides: Record<string, string> = {}): void => {
    // The real build reads process.env, so clear CI markers this run may have.
    for (const key of ['NETLIFY', 'CI', 'GITHUB_ACTIONS', 'RENDER', 'RENDER_SERVICE_ID', 'RENDER_EXTERNAL_URL', 'RENDER_GIT_COMMIT']) vi.stubEnv(key, '')
    for (const [key, value] of Object.entries({ ...localBuild, ...overrides })) vi.stubEnv(key, value)
  }

  afterEach(() => {
    vi.unstubAllEnvs()
    for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
  })

  it('runs the local build checks from vite.config', () => {
    stubLocal()
    expect(build).not.toThrow()
    stubLocal({ CI: 'true' })
    expect(build).toThrow(/hosted platform or CI/)
    stubLocal({ VITE_CLERK_PUBLISHABLE_KEY: publishableKey('clerk.shimizu-technology.com', 'pk_live_') })
    expect(build).toThrow(/live keys/)
  })

  it('leaves PostHog out of local staff headers but keeps it for production', () => {
    const enabled = { VITE_PUBLIC_POSTHOG_ENABLED: 'true', VITE_PUBLIC_POSTHOG_KEY: 'phc_test' }
    const localDir = dist()
    expect(finalizeStaffDist({ distDir: localDir, env: { ...localBuild, ...enabled } }).posthog).toBeNull()
    expect(readFileSync(path.join(localDir, '_headers'), 'utf8')).not.toMatch(/posthog/)

    const productionDir = dist()
    finalizeStaffDist({ distDir: productionDir, env: { VITE_DEPLOYMENT_ENV: 'production', VITE_API_URL: 'https://cornerstone-payroll.onrender.com/api/v1' } })
    expect(readFileSync(path.join(productionDir, '_headers'), 'utf8')).toMatch(/us\.i\.posthog\.com/)
  })

  it('allows the development Clerk key for a local employee build only', () => {
    const deployDir = path.join(webDir, 'deploy', 'employee')
    const localDir = dist()
    const origins = finalizeEmployeeDist({ distDir: localDir, deployDir, env: { ...localBuild, VITE_PUBLIC_POSTHOG_ENABLED: 'true', VITE_PUBLIC_POSTHOG_KEY: 'phc_test' } })
    expect(origins.clerkOrigin).toBe('https://example-local-1.clerk.accounts.dev')
    expect(origins.posthog).toBeNull()
    expect(readFileSync(path.join(localDir, '_headers'), 'utf8')).not.toMatch(/posthog/)
    expect(() => finalizeEmployeeDist({ distDir: dist(), deployDir, env: { ...localBuild, VITE_DEPLOYMENT_ENV: 'production' } })).toThrow(/pk_live_/)
  })
})
