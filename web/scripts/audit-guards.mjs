import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { evaluateAudit } from './audit-check.mjs'
const allowlist = JSON.parse(readFileSync(new URL('./audit-allowlist.json', import.meta.url)))
const entry = allowlist.find(e => e.package === 'picomatch' && e.project === '.')
const report = {
  auditReportVersion: 2,
  vulnerabilities: { picomatch: {
    name: 'picomatch', severity: 'high', isDirect: false, range: entry.range,
    nodes: entry.nodes, via: [{ title: 'ReDoS', severity: 'high', url: `https://github.com/advisories/${entry.advisory}` }],
  } },
  metadata: {
    vulnerabilities: { info: 0, low: 0, moderate: 0, high: 1, critical: 0, total: 1 },
    dependencies: { prod: 0, dev: 1, optional: 0, peer: 0, peerOptional: 0, total: 1 },
  },
}
const options = { project: '.', today: '2026-11-18' }
assert.equal(evaluateAudit(report, allowlist, options).problems.length, 0)
assert.equal(evaluateAudit(report, allowlist, { ...options, today: '2026-12-19' }).problems.length, 1)
for (const alter of [
  r => { r.vulnerabilities.picomatch.isDirect = true },
  r => { r.vulnerabilities.picomatch.nodes = ['node_modules/new-consumer/node_modules/picomatch'] },
  r => { r.vulnerabilities.picomatch.range = '<=5' },
  r => { r.vulnerabilities.picomatch.via[0].url = 'https://github.com/advisories/GHSA-new-advisory' },
]) {
  const changed = structuredClone(report); alter(changed)
  assert.equal(evaluateAudit(changed, allowlist, options).problems.length, 1)
}
assert.throws(() => evaluateAudit({}, allowlist, options))
assert.throws(() => evaluateAudit({ ...report, error: { message: 'registry unavailable' } }, allowlist, options))
console.log('Audit exception guards pass: exact advisory, expiry, scope, new advisory, incomplete report and service error')

// Exercise the actual CLI too: registry failures must never look like a clean audit.
const { spawnSync } = await import('node:child_process')
const { mkdtempSync, writeFileSync, chmodSync, rmSync } = await import('node:fs')
const { tmpdir } = await import('node:os')
const path = await import('node:path')
const { fileURLToPath } = await import('node:url')
const bin = mkdtempSync(path.join(tmpdir(), 'audit-cli-guards-'))
try {
  const npm = path.join(bin, 'npm')
  writeFileSync(npm, '#!/bin/sh\nprintf "%s" "$AUDIT_GUARD_OUTPUT"\nexit "$AUDIT_GUARD_STATUS"\n')
  chmodSync(npm, 0o755)
  const root = fileURLToPath(new URL('..', import.meta.url))
  const script = fileURLToPath(new URL('./audit-check.mjs', import.meta.url))
  for (const [label, output, status, expected] of [
    ['reviewed advisory', JSON.stringify(report), '1', 0],
    ['invalid JSON', '{broken', '1', 1],
    ['missing metadata', '{}', '0', 1],
    ['registry error', JSON.stringify({ error: { message: 'unavailable' } }), '1', 1],
    ['unexpected npm status', JSON.stringify(report), '2', 1],
  ]) {
    const result = spawnSync(process.execPath, [script, root], {
      encoding: 'utf8',
      env: { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`, AUDIT_GUARD_OUTPUT: output, AUDIT_GUARD_STATUS: status },
    })
    assert.equal(result.status, expected, `${label}: ${result.stdout}\n${result.stderr}`)
    if (expected) assert.doesNotMatch(result.stdout, /No unreviewed/)
  }
} finally {
  rmSync(bin, { recursive: true, force: true })
}
console.log('Audit CLI rejects registry/JSON/schema/status failures')
