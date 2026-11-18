#!/usr/bin/env node
// npm audit gate for the frontend.
// Fails on any advisory at moderate or above, except the reviewed exceptions
// below. Each exception names one advisory, says why it is safe to accept for
// now, and expires so it is looked at again.

import { execFileSync } from 'node:child_process'

const EXCEPTIONS = [
  {
    id: 'GHSA-fc5q-39xc-vjpf',
    expires: '2027-01-31',
    reason:
      'picomatch ReDoS (CVE-2026-112366). No patched release exists for any version and the ' +
      'advisory is disputed upstream (micromatch/picomatch#234). picomatch is dev-only here ' +
      '(Vite, Vitest, typescript-eslint), never ships to the browser, and only reads glob ' +
      'patterns from our own config. Remove once a fixed picomatch ships or the advisory is withdrawn.',
  },
]

const LEVELS = ['info', 'low', 'moderate', 'high', 'critical']
const FAIL_AT = LEVELS.indexOf('moderate')

function runAudit() {
  try {
    return execFileSync('npm', ['audit', '--json'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
  } catch (error) {
    // npm audit exits non-zero whenever it finds anything; the JSON is still on stdout.
    if (error.stdout) return error.stdout
    throw error
  }
}

const report = JSON.parse(runAudit())
if (report.error) {
  console.error('npm audit failed:', report.error.summary || JSON.stringify(report.error))
  process.exit(1)
}

// Every flagged package traces back to one or more advisory objects in a `via` list.
const advisories = new Map()
for (const vulnerability of Object.values(report.vulnerabilities || {})) {
  for (const via of vulnerability.via || []) {
    if (typeof via === 'object' && via.url) advisories.set(via.url, via)
  }
}

const today = new Date().toISOString().slice(0, 10)
const seenExceptions = new Set()
const blocking = []

for (const advisory of advisories.values()) {
  if (LEVELS.indexOf(advisory.severity) < FAIL_AT) continue

  const exception = EXCEPTIONS.find((entry) => advisory.url.endsWith(entry.id))
  if (exception) {
    seenExceptions.add(exception.id)
    if (today <= exception.expires) {
      console.log(`Accepted until ${exception.expires}: ${advisory.name} ${advisory.severity} ${exception.id}`)
      console.log(`  ${exception.reason}`)
      continue
    }
    console.error(`Exception for ${exception.id} expired on ${exception.expires}; review it again.`)
  }
  blocking.push(advisory)
}

for (const exception of EXCEPTIONS) {
  if (!seenExceptions.has(exception.id)) {
    console.log(`Note: ${exception.id} is no longer reported; remove its exception from scripts/audit-gate.mjs.`)
  }
}

if (blocking.length > 0) {
  console.error(`\n${blocking.length} advisory(ies) at moderate or above:`)
  for (const advisory of blocking) {
    console.error(`- ${advisory.name} (${advisory.severity}): ${advisory.title} ${advisory.url}`)
  }
  process.exit(1)
}

console.log('npm audit gate: OK')
