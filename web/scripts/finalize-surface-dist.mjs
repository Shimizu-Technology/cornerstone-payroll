#!/usr/bin/env node
// Runs after `vite build` (npm "postbuild"). A no-op for the staff surface, so
// the Payroll site's output is unchanged. For VITE_APP_SURFACE=employee it
// writes the employee site's _headers and _redirects into dist and removes
// staff-only static files. Pay data never goes through a cache or a crawler.
import { copyFileSync, cpSync, existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { loadEnv } from 'vite'

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const STAFF_ONLY_FILES = ['sw.js', 'offline.html', 'sitemap.xml', 'manifest.json', 'favicon.svg', 'icon-192.png', 'icon-512.png', 'og-image.png']
const ROBOTS_TXT = '# Employee app: nothing here is for search engines.\nUser-agent: *\nDisallow: /\n'
const DEFAULT_STAFF_API_ORIGIN = 'https://cornerstone-payroll.onrender.com'
const DEFAULT_STAFF_CLERK_ORIGIN = 'https://clerk.shimizu-technology.com'

export function apiOrigin(apiUrl) {
  let url
  try {
    url = new URL(String(apiUrl ?? ''))
  } catch {
    throw new Error('VITE_API_URL must be an absolute https URL for the employee build')
  }
  if (url.protocol !== 'https:' || url.username || url.password) {
    throw new Error('VITE_API_URL must be an absolute https URL for the employee build')
  }
  return url.origin
}

export function staffApiOrigins(apiUrl) {
  const raw = String(apiUrl ?? '').trim()
  if (!raw || raw.startsWith('/')) {
    return {
      httpOrigin: DEFAULT_STAFF_API_ORIGIN,
      wsOrigin: DEFAULT_STAFF_API_ORIGIN.replace(/^https:/, 'wss:'),
    }
  }
  let url
  try {
    url = new URL(raw)
  } catch {
    throw new Error('VITE_API_URL must be a valid http(s) URL or relative path for the staff build')
  }
  if ((url.protocol !== 'https:' && url.protocol !== 'http:') || url.username || url.password) {
    throw new Error('VITE_API_URL must be a valid http(s) URL without credentials for the staff build')
  }
  const wsProtocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
  return {
    httpOrigin: url.origin,
    wsOrigin: `${wsProtocol}//${url.host}`,
  }
}

const DEFAULT_POSTHOG_HOST = 'https://us.i.posthog.com'
const POSTHOG_US_HOSTS = new Set(['app.posthog.com', 'us.posthog.com', 'us.i.posthog.com', 'us-assets.i.posthog.com'])
const POSTHOG_EU_HOSTS = new Set(['eu.posthog.com', 'eu.i.posthog.com', 'eu-assets.i.posthog.com'])

export function posthogOrigins(env = {}) {
  if (env.VITE_DEPLOYMENT_ENV === 'staging') return null
  if (env.VITE_PUBLIC_POSTHOG_ENABLED !== 'true') return null
  const key = String(env.VITE_PUBLIC_POSTHOG_KEY ?? '').trim()
  if (!key || key === 'YOUR_POSTHOG_KEY') return null

  const rawHost = String(env.VITE_PUBLIC_POSTHOG_HOST ?? '').trim() || DEFAULT_POSTHOG_HOST
  let url
  try {
    url = new URL(rawHost)
  } catch {
    throw new Error('VITE_PUBLIC_POSTHOG_HOST must be an absolute https URL when PostHog is enabled')
  }
  if (url.protocol !== 'https:' || url.username || url.password || url.port) {
    throw new Error('VITE_PUBLIC_POSTHOG_HOST must be an official PostHog HTTPS host when PostHog is enabled')
  }

  const hostname = url.hostname.toLowerCase()
  if (POSTHOG_US_HOSTS.has(hostname)) {
    return {
      apiOrigin: DEFAULT_POSTHOG_HOST,
      assetsOrigin: 'https://us-assets.i.posthog.com',
    }
  }
  if (POSTHOG_EU_HOSTS.has(hostname)) {
    return {
      apiOrigin: 'https://eu.i.posthog.com',
      assetsOrigin: 'https://eu-assets.i.posthog.com',
    }
  }
  throw new Error(
    'VITE_PUBLIC_POSTHOG_HOST must be an official PostHog US or EU host (e.g. https://us.i.posthog.com or https://eu.i.posthog.com)',
  )
}

// Same host rule as ClerkTokenVerifier::HOSTNAME_PATTERN (api/app/services/clerk_token_verifier.rb),
// so the build accepts exactly the frontend API hosts the API would verify tokens for.
const CLERK_HOSTNAME = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/i

// A Clerk publishable key is `pk_<env>_` plus base64 of "<frontend API host>$".
// A production build refuses a `pk_test_` (development instance) key.
export function clerkFrontendOrigin(publishableKey, { production = false } = {}) {
  const match = /^pk_(test|live)_([A-Za-z0-9+/=_-]+)$/.exec(String(publishableKey ?? ''))
  const decoded = match && Buffer.from(match[2], 'base64').toString('utf8')
  const host = decoded?.endsWith('$') ? decoded.slice(0, -1) : ''
  if (!match || !CLERK_HOSTNAME.test(host)) {
    throw new Error('VITE_CLERK_PUBLISHABLE_KEY must be a Clerk publishable key for the employee build')
  }
  if (production && match[1] !== 'live') {
    throw new Error('VITE_CLERK_PUBLISHABLE_KEY must be a pk_live_ key when VITE_DEPLOYMENT_ENV=production')
  }
  return `https://${host.toLowerCase()}`
}

// Sources follow Clerk's CSP guide for a self-hosted frontend (production instance, own
// Clerk frontend API domain): https://clerk.com/docs/guides/secure/best-practices/csp-headers
//   script-src  frontend API host, https://challenges.cloudflare.com, https://*.protect.clerk.com
//   connect-src frontend API host, https://*.protect.clerk.com:*  (":*" is required: those hosts use ports other than 443)
//   frame-src   https://challenges.cloudflare.com, https://*.protect.clerk.com
//   img-src     https://img.clerk.com
//   worker-src  'self' blob:      style-src 'self' 'unsafe-inline'      form-action 'self'
// Beyond that guide: the employee API, Clerk telemetry, Google Fonts, tenant logo hosts, and
// (only when PostHog is enabled in the build) the exact official PostHog ingestion and assets
// origins (e.g. https://us.i.posthog.com and https://us-assets.i.posthog.com). Custom hosts
// are rejected so script-src is never opened to arbitrary third-party domains.
// The only wildcards allowed are the documented Clerk ones (employeeSurfaceDeploy.test.ts enforces that).
export function contentSecurityPolicy({ apiOrigin: api, clerkOrigin, posthog = null }) {
  const posthogScriptSources = posthog ? [posthog.assetsOrigin] : []
  const posthogConnectSources = posthog
    ? Array.from(new Set([posthog.apiOrigin, posthog.assetsOrigin]))
    : []
  const scriptSrc = [
    "'self'",
    clerkOrigin,
    'https://challenges.cloudflare.com',
    'https://*.protect.clerk.com',
    ...posthogScriptSources,
  ].join(' ')
  const connectSrc = [
    "'self'",
    api,
    clerkOrigin,
    'https://*.protect.clerk.com:*',
    'https://clerk-telemetry.com',
    'https://*.clerk-telemetry.com',
    ...posthogConnectSources,
  ].join(' ')

  return [
    "default-src 'self'",
    "manifest-src blob:",
    `script-src ${scriptSrc}`,
    // Clerk's components and the Google Fonts stylesheet in index.html inject styles.
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "font-src 'self' https://fonts.gstatic.com data:",
    // https://img.clerk.com is Clerk's avatar host. Tenant logos come from a public HTTPS asset host
    // that differs per client, so any HTTPS image source stays allowed.
    "img-src 'self' data: blob: https://img.clerk.com https:",
    `connect-src ${connectSrc}`,
    "frame-src 'self' blob: https://challenges.cloudflare.com https://*.protect.clerk.com",
    "worker-src 'self' blob:",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    'upgrade-insecure-requests',
  ].join('; ')
}

export function renderHeaders(template, origins) {
  const csp = contentSecurityPolicy(origins)
  const rendered = template.replaceAll('{{CSP}}', csp)
  if (/\{\{[A-Z_]+\}\}/.test(rendered)) throw new Error('Unfilled placeholder in employee _headers template')
  return rendered
}

export function finalizeEmployeeDist({ distDir, deployDir, env }) {
  if (!existsSync(path.join(distDir, 'index.html'))) throw new Error(`No build output in ${distDir}`)
  const origins = {
    apiOrigin: apiOrigin(env.VITE_API_URL),
    clerkOrigin: clerkFrontendOrigin(env.VITE_CLERK_PUBLISHABLE_KEY, {
      production: env.VITE_DEPLOYMENT_ENV === 'production',
    }),
    posthog: posthogOrigins(env),
  }
  writeFileSync(
    path.join(distDir, '_headers'),
    renderHeaders(readFileSync(path.join(deployDir, '_headers.template'), 'utf8'), origins),
  )
  cpSync(path.join(deployDir, 'legal'), path.join(distDir, 'legal'), { recursive: true })
  copyFileSync(path.join(deployDir, '_redirects'), path.join(distDir, '_redirects'))
  writeFileSync(path.join(distDir, 'robots.txt'), ROBOTS_TXT)
  for (const file of STAFF_ONLY_FILES) rmSync(path.join(distDir, file), { force: true })
  return origins
}

export function staffReportOnlyCsp({ apiOrigin: api, apiWsOrigin, clerkOrigin, posthog = null }) {
  const posthogScriptSources = posthog ? [posthog.assetsOrigin] : []
  const posthogConnectSources = posthog
    ? Array.from(new Set([posthog.apiOrigin, posthog.assetsOrigin]))
    : []
  const scriptSrc = [
    "'self'",
    clerkOrigin,
    'https://challenges.cloudflare.com',
    'https://*.protect.clerk.com',
    ...posthogScriptSources,
  ].join(' ')
  const connectSrc = [
    "'self'",
    api,
    apiWsOrigin,
    clerkOrigin,
    'https://*.protect.clerk.com:*',
    'https://clerk-telemetry.com',
    'https://*.clerk-telemetry.com',
    'https://*.r2.cloudflarestorage.com',
    ...posthogConnectSources,
  ].join(' ')

  return [
    "default-src 'self'",
    `script-src ${scriptSrc}`,
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "font-src 'self' https://fonts.gstatic.com data:",
    // Allow configurable external HTTPS tenant logo URLs shown in staff Employee App Settings.
    `img-src 'self' data: blob: https://img.clerk.com https://*.r2.cloudflarestorage.com ${api} https:`,
    `connect-src ${connectSrc}`,
    "frame-src 'self' blob: https://challenges.cloudflare.com https://*.protect.clerk.com",
    "worker-src 'self' blob:",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
  ].join('; ')
}

export function renderStaffHeaders(origins) {
  const cspReportOnly = staffReportOnlyCsp(origins)
  return [
    '# Staff surface headers generated by scripts/finalize-surface-dist.mjs from build configuration.',
    '/*',
    "  Content-Security-Policy: frame-ancestors 'none'",
    `  Content-Security-Policy-Report-Only: ${cspReportOnly}`,
    '  X-Frame-Options: DENY',
    '  X-Content-Type-Options: nosniff',
    '  Referrer-Policy: no-referrer',
    '  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()',
    '  Cross-Origin-Opener-Policy: same-origin-allow-popups',
    '',
  ].join('\n')
}

export function finalizeStaffDist({ distDir, env }) {
  if (!existsSync(path.join(distDir, 'index.html'))) throw new Error(`No build output in ${distDir}`)
  const { httpOrigin, wsOrigin } = staffApiOrigins(env.VITE_API_URL)
  const clerkOrigin = String(env.VITE_CLERK_PUBLISHABLE_KEY ?? '').trim()
    ? clerkFrontendOrigin(env.VITE_CLERK_PUBLISHABLE_KEY, {
      production: env.VITE_DEPLOYMENT_ENV === 'production',
    })
    : DEFAULT_STAFF_CLERK_ORIGIN
  const posthog = posthogOrigins(env) ?? (env.VITE_DEPLOYMENT_ENV === 'staging'
    ? null
    : { apiOrigin: DEFAULT_POSTHOG_HOST, assetsOrigin: 'https://us-assets.i.posthog.com' })
  const origins = { apiOrigin: httpOrigin, apiWsOrigin: wsOrigin, clerkOrigin, posthog }
  writeFileSync(path.join(distDir, '_headers'), renderStaffHeaders(origins))
  return origins
}

export function main(env = { ...loadEnv('production', webDir, ''), ...process.env }, { distDir = path.join(webDir, 'dist') } = {}) {
  const surface = env.VITE_APP_SURFACE ?? 'staff'
  if (surface !== 'employee') {
    const origins = finalizeStaffDist({ distDir, env })
    console.log(`Staff deploy headers written (API ${origins.apiOrigin}, Clerk ${origins.clerkOrigin}).`)
    return
  }
  const origins = finalizeEmployeeDist({
    distDir,
    deployDir: path.join(webDir, 'deploy', 'employee'),
    env,
  })
  console.log(`Employee deploy files written (API ${origins.apiOrigin}, Clerk ${origins.clerkOrigin}).`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main()
