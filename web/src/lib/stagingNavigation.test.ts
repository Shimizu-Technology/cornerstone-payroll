import { afterEach, expect, it, vi } from 'vitest'
afterEach(() => { vi.unstubAllEnvs(); vi.resetModules() })
it('only permits the exact configured staging origin and rejects stale saved origins', async () => {
  vi.stubEnv('VITE_DEPLOYMENT_ENV', 'staging')
  vi.stubEnv('VITE_STAGING_AIRE_FRONTEND_ORIGIN', 'https://peer-staging.example.test')
  const { stagingNavigationUrl } = await import('./staging')
  const good = 'https://peer-staging.example.test/admin/payroll-link?token=synthetic'
  expect(stagingNavigationUrl(good, 'https://peer-staging.example.test')).toBe(good)
  for (const bad of [
    'https://app.aireservicesguam.com/admin/payroll-link?token=synthetic',
    'https://aire-services-guam.netlify.app/admin/payroll-link?token=synthetic',
    'https://PEER-STAGING.example.test/admin/payroll-link?token=synthetic',
    'https://other-staging.example.test/admin/payroll-link?token=synthetic',
    'https://peer-staging.example.test.evil.test/admin/payroll-link',
    'https://user@peer-staging.example.test/admin/payroll-link',
    'https://peer-staging.example.test:443/admin/payroll-link',
    'http://peer-staging.example.test/admin/payroll-link',
    ' https://peer-staging.example.test/admin/payroll-link',
    '/admin/payroll-link',
  ]) expect(() => stagingNavigationUrl(bad)).toThrow(/staging connection/i)
  expect(() => stagingNavigationUrl(good, 'https://production.example.test')).toThrow()
})
it('fails closed when the staging origin is missing or a production alias', async () => {
  vi.stubEnv('VITE_DEPLOYMENT_ENV', 'staging')
  const { stagingNavigationUrl } = await import('./staging')
  vi.stubEnv('VITE_STAGING_AIRE_FRONTEND_ORIGIN', '')
  expect(() => stagingNavigationUrl('https://peer-staging.example.test/path')).toThrow()
  vi.stubEnv('VITE_STAGING_AIRE_FRONTEND_ORIGIN', 'https://app.aireservicesguam.com')
  expect(() => stagingNavigationUrl('https://app.aireservicesguam.com/path')).toThrow()
})
it('preserves ordinary production navigation', async () => {
  vi.stubEnv('VITE_DEPLOYMENT_ENV', 'production')
  const { stagingNavigationUrl } = await import('./staging')
  expect(stagingNavigationUrl('https://production.example.test/path')).toBe('https://production.example.test/path')
})
