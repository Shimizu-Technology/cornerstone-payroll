#!/usr/bin/env node
// Runs after `vite build` (npm "postbuild"). A no-op for the staff surface, so
// the Payroll site's output is unchanged. For VITE_APP_SURFACE=employee it
// writes the employee site's _headers and _redirects into dist and removes
// staff-only static files. Pay data never goes through a cache or a crawler.
import { copyFileSync, existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { loadEnv } from 'vite'

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const STAFF_ONLY_FILES = ['sw.js', 'offline.html', 'sitemap.xml']
const ROBOTS_TXT = '# Employee app: nothing here is for search engines.\nUser-agent: *\nDisallow: /\n'

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

// A Clerk publishable key is `pk_<env>_` plus base64 of "<frontend API host>$".
export function clerkFrontendOrigin(publishableKey) {
  const match = /^pk_(?:test|live)_([A-Za-z0-9+/=_-]+)$/.exec(String(publishableKey ?? ''))
  const host = match && Buffer.from(match[1], 'base64').toString('utf8')
  if (!host || !host.endsWith('$') || !/^[a-z0-9.-]+\$$/i.test(host)) {
    throw new Error('VITE_CLERK_PUBLISHABLE_KEY must be a Clerk publishable key for the employee build')
  }
  return `https://${host.slice(0, -1).toLowerCase()}`
}

export function contentSecurityPolicy({ apiOrigin: api, clerkOrigin }) {
  return [
    "default-src 'self'",
    `script-src 'self' ${clerkOrigin} https://challenges.cloudflare.com`,
    // Clerk's components and the Google Fonts stylesheet in index.html inject styles.
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "font-src 'self' https://fonts.gstatic.com data:",
    // Tenant logos come from a public HTTPS asset host that differs per client.
    "img-src 'self' data: blob: https:",
    `connect-src 'self' ${api} ${clerkOrigin} https://clerk-telemetry.com`,
    "frame-src 'self' blob: https://challenges.cloudflare.com",
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
    clerkOrigin: clerkFrontendOrigin(env.VITE_CLERK_PUBLISHABLE_KEY),
  }
  writeFileSync(
    path.join(distDir, '_headers'),
    renderHeaders(readFileSync(path.join(deployDir, '_headers.template'), 'utf8'), origins),
  )
  copyFileSync(path.join(deployDir, '_redirects'), path.join(distDir, '_redirects'))
  writeFileSync(path.join(distDir, 'robots.txt'), ROBOTS_TXT)
  for (const file of STAFF_ONLY_FILES) rmSync(path.join(distDir, file), { force: true })
  return origins
}

export function main(env = { ...loadEnv('production', webDir, ''), ...process.env }) {
  const surface = env.VITE_APP_SURFACE ?? 'staff'
  if (surface !== 'employee') {
    console.log(`Surface "${surface}": no deploy files to finalize.`)
    return
  }
  const origins = finalizeEmployeeDist({
    distDir: path.join(webDir, 'dist'),
    deployDir: path.join(webDir, 'deploy', 'employee'),
    env,
  })
  console.log(`Employee deploy files written (API ${origins.apiOrigin}, Clerk ${origins.clerkOrigin}).`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main()
