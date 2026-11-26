// Browser smoke check for the local production copy: a real Clerk sign-in on
// the staff site, then the API calls the app itself makes with that session.
// Run by smoke.sh; reads the staff password from the mirror's secrets file.
//
// Chromium trusts the mirror's certificate here without the keychain step
// (ignoreHTTPSErrors). Everything else is the production path.
import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'
import path from 'node:path'

const [webDir, secretsFile, clerkJson, staffOrigin, apiOrigin, tenantOrigin] = process.argv.slice(2)
const { chromium } = createRequire(path.join(webDir, 'package.json'))('@playwright/test')
const password = /^LP_STAFF_PASSWORD='([^']+)'$/m.exec(readFileSync(secretsFile, 'utf8'))?.[1]
const { staff_email: email } = JSON.parse(readFileSync(clerkJson, 'utf8'))
if (!password || !email) throw new Error('missing staff login')

const results = []
const record = (name, passed, detail = '') => {
  results.push({ name, passed })
  console.log(`${passed ? 'PASS' : 'FAIL'}  ${name}${detail ? `  (${detail})` : ''}`)
}

const browser = await chromium.launch()
try {
  const context = await browser.newContext({ ignoreHTTPSErrors: true })
  const page = await context.newPage()
  await page.goto(`${staffOrigin}/login`, { waitUntil: 'domcontentloaded' })

  // Clerk's sign-in: email, then password.
  const identifier = page.locator('input[name="identifier"]')
  await identifier.waitFor({ timeout: 60_000 })
  await identifier.fill(email)
  await page.getByRole('button', { name: 'Continue', exact: true }).click()
  const passwordField = page.locator('input[name="password"]')
  await passwordField.waitFor({ timeout: 30_000 })
  await passwordField.fill(password)
  await page.getByRole('button', { name: 'Continue', exact: true }).click()
  // A new browser gets Clerk's emailed-code check; +clerk_test addresses take 424242.
  const signedIn = page.waitForFunction(() => Boolean(window.Clerk?.session), null, { timeout: 60_000 })
  const code = page.locator('input[autocomplete="one-time-code"], input[name="code"]').first()
  if (await code.waitFor({ timeout: 15_000 }).then(() => true, () => false)) {
    await code.click()
    await page.keyboard.type('424242')
  }
  await signedIn
  record('staff signs in through Clerk on the staff site', true)

  const call = (url, companyId) => page.evaluate(async ([target, company]) => {
    const token = await window.Clerk.session.getToken()
    const response = await fetch(target, { headers: { Authorization: `Bearer ${token}`, ...(company ? { 'X-Company-Id': String(company) } : {}) } })
    return { status: response.status, body: await response.json().catch(() => null) }
  }, [url, companyId])

  const me = await call(`${apiOrigin}/api/v1/auth/me`)
  const user = me.body?.user ?? me.body?.data ?? me.body
  record('the staff API accepts the Clerk session', me.status === 200, `HTTP ${me.status}${user?.role ? `, role ${user.role}` : ''}`)

  const companies = await call(`${apiOrigin}/api/v1/admin/companies`)
  const list = companies.body?.companies ?? companies.body?.data ?? []
  const kitchen = list.find((company) => company.subdomain_slug === 'harborfinch' || company.name === 'Harbor Finch Kitchen')
  record('the staff API lists the Harbor Finch demo company', Boolean(kitchen), `HTTP ${companies.status}`)

  if (kitchen) {
    const state = await call(`${apiOrigin}/api/v1/admin/employee_app_switch`, kitchen.id)
    const checks = state.body?.data?.readiness?.checks ?? state.body?.data?.checks ?? []
    const failing = checks.filter((check) => check.status === 'failed').map((check) => check.key)
    record('the switch page reports no failing readiness check', state.status === 200 && checks.length > 0 && failing.length === 0,
      `HTTP ${state.status}; ${checks.map((check) => `${check.key}=${check.status}`).join(' ')}`)
  }

  const tenant = await context.newPage()
  const response = await tenant.goto(tenantOrigin, { waitUntil: 'domcontentloaded' })
  const csp = response?.headers()['content-security-policy'] ?? ''
  record('the employee address serves the employee app with its CSP', response?.status() === 200 && csp.includes('employee-api.'),
    `HTTP ${response?.status()}`)
} finally {
  await browser.close()
}
process.exit(results.every((result) => result.passed) ? 0 : 1)
