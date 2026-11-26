import { describe, expect, it } from 'vitest'
import { assertDeploymentFlags, assertLocalBuild } from '../../build/staging'
import { posthogOrigins } from '../../scripts/finalize-surface-dist.mjs'
import { shouldEnableAnalytics } from './analytics'
import { clientSubdomainHost, DEFAULT_TENANT_ROOT_DOMAIN, tenantRootDomain } from './tenant-subdomain'

const localBuild = {
  DEPLOYMENT_ENV: 'local',
  VITE_DEPLOYMENT_ENV: 'local',
  VITE_CLERK_PUBLISHABLE_KEY: 'pk_test_local',
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
