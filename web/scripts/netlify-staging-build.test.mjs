import { test } from 'node:test'
import assert from 'node:assert/strict'
import { stagingEnvironment } from './netlify-staging-build.mjs'
const valid = {
  CONTEXT: 'branch-deploy', BRANCH: 'staging', COMMIT_REF: 'a'.repeat(40),
  NETLIFY_STAGING_API_URL: 'https://api-staging.example.test/api/v1',
  NETLIFY_STAGING_CLERK_PUBLISHABLE_KEY: 'pk_test_synthetic',
  NETLIFY_STAGING_SNAPSHOT_AT: '2026-11-18T00:00:00Z',
  DEPLOY_PRIME_URL: 'https://staging--example.netlify.app',
  VITE_API_URL: 'https://production.example.test/api/v1',
  VITE_CLERK_PUBLISHABLE_KEY: 'pk_live_synthetic', VITE_AUTH_ENABLED: 'false',
}
test('staging overrides inherited production configuration and uses the build SHA', () => {
  const env = stagingEnvironment(valid)
  assert.equal(env.VITE_API_URL, valid.NETLIFY_STAGING_API_URL)
  assert.equal(env.VITE_CLERK_PUBLISHABLE_KEY, valid.NETLIFY_STAGING_CLERK_PUBLISHABLE_KEY)
  assert.equal(env.VITE_STAGING_CODE_SHA, valid.COMMIT_REF)
  assert.equal(env.DEPLOYMENT_ENV, 'staging')
  assert.equal(env.VITE_DEPLOYMENT_ENV, 'staging')
  assert.equal(env.VITE_AUTH_ENABLED, 'true')
  assert.equal(env.VITE_SITE_URL, valid.DEPLOY_PRIME_URL)
})
test('PR preview also uses staging, never production', () => {
  assert.equal(stagingEnvironment({ ...valid, CONTEXT: 'deploy-preview', BRANCH: 'feature' }).VITE_DEPLOYMENT_ENV, 'staging')
})
test('missing dedicated values cannot fall back to production', () => {
  for (const key of ['NETLIFY_STAGING_API_URL', 'NETLIFY_STAGING_CLERK_PUBLISHABLE_KEY', 'NETLIFY_STAGING_SNAPSHOT_AT', 'COMMIT_REF']) {
    assert.throws(() => stagingEnvironment({ ...valid, [key]: '' }))
  }
})
test('reject unsafe APIs, production context, other branches, live keys and bad metadata', () => {
  for (const url of ['https://production.example.test', 'http://api-staging.example.test', 'https://user:pass@api-staging.example.test', 'https://api-staging.example.test:444', 'https://api-staging.example.test?token=secret']) {
    assert.throws(() => stagingEnvironment({ ...valid, NETLIFY_STAGING_API_URL: url }))
  }
  for (const override of [{ CONTEXT: 'production' }, { BRANCH: 'main' },
    { NETLIFY_STAGING_CLERK_PUBLISHABLE_KEY: 'pk_live_synthetic' }, { COMMIT_REF: 'short' },
    { NETLIFY_STAGING_SNAPSHOT_AT: 'invalid' }]) {
    assert.throws(() => stagingEnvironment({ ...valid, ...override }))
  }
})
