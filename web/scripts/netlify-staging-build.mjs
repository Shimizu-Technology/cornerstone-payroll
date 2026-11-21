import { spawnSync } from 'node:child_process'
import { pathToFileURL } from 'node:url'

// Preview builds must never inherit production API/auth configuration.
export function stagingEnvironment(source) {
  if (!['branch-deploy', 'deploy-preview'].includes(source.CONTEXT) ||
      (source.CONTEXT === 'branch-deploy' && source.BRANCH !== 'staging')) {
    throw new Error('Only staging branch deploys and Deploy Previews are supported')
  }
  const required = ['NETLIFY_STAGING_API_URL', 'NETLIFY_STAGING_CLERK_PUBLISHABLE_KEY',
    'NETLIFY_STAGING_SNAPSHOT_AT', 'COMMIT_REF']
  if (required.some(key => !source[key])) throw new Error('Missing dedicated staging build configuration')
  let api
  try { api = new URL(source.NETLIFY_STAGING_API_URL) } catch { throw new Error('Invalid staging API URL') }
  if (api.protocol !== 'https:' || api.port || api.username || api.password || api.search || api.hash ||
      !/(?:^|[.-])staging(?:[.-]|$)/.test(api.hostname)) throw new Error('Staging API must use an HTTPS staging host')
  if (!source.NETLIFY_STAGING_CLERK_PUBLISHABLE_KEY.startsWith('pk_test_')) throw new Error('Staging requires a test Clerk key')
  if (!/^[0-9a-f]{40}$/.test(source.COMMIT_REF)) throw new Error('Missing full build commit SHA')
  if (Number.isNaN(Date.parse(source.NETLIFY_STAGING_SNAPSHOT_AT))) throw new Error('Invalid staging snapshot timestamp')
  const env = Object.fromEntries(Object.entries(source).filter(([key]) => !key.startsWith('VITE_')))
  Object.assign(env, {
    DEPLOYMENT_ENV: 'staging', VITE_DEPLOYMENT_ENV: 'staging', VITE_AUTH_ENABLED: 'true',
    VITE_API_URL: source.NETLIFY_STAGING_API_URL,
    VITE_CLERK_PUBLISHABLE_KEY: source.NETLIFY_STAGING_CLERK_PUBLISHABLE_KEY,
    VITE_STAGING_SNAPSHOT_AT: source.NETLIFY_STAGING_SNAPSHOT_AT,
    VITE_STAGING_CODE_SHA: source.COMMIT_REF,
    VITE_SITE_URL: source.DEPLOY_PRIME_URL,
    VITE_STAGING_AIRE_FRONTEND_ORIGIN: 'https://staging--aire-services-guam.netlify.app',
    VITE_STAGING_PAYROLL_FRONTEND_ORIGIN: 'https://staging--cornerstone-payroll.netlify.app',
    VITE_PUBLIC_POSTHOG_ENABLED: 'false', VITE_PUBLIC_POSTHOG_KEY: '',
    VITE_GOOGLE_MAPS_API_KEY: '', VITE_CLERK_JWT_TEMPLATE: source.NETLIFY_STAGING_CLERK_JWT_TEMPLATE || '',
  })
  return env
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const env = stagingEnvironment(process.env)
    const result = spawnSync('npm', ['run', 'build'], { env, stdio: 'inherit' })
    process.exit(result.error ? 1 : result.status ?? 1)
  } catch (error) {
    console.error(error.message) // Configuration names/reasons only; never print values.
    process.exit(1)
  }
}
