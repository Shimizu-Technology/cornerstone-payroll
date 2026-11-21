import assert from 'node:assert/strict'
import { evaluateAudit } from './audit-check.mjs'
const entry = { advisory: 'GHSA-fc5q-39xc-vjpf', package: 'picomatch', project: '.', via: 'fixture', reason: 'synthetic build-tool fixture', reviewBy: '2026-12-18', isDirect: false, range: '*', nodes: ['node_modules/picomatch'], reviewedConsumers: ['vite'], devOnly: true }
const allowlist = [entry]
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
const options = { project: '.', today: '2026-11-18', lockPackages: { 'node_modules/picomatch': { dev: true } } }
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
  writeFileSync(npm, '#!/bin/sh\ncase " $* " in *" --include=dev "*) ;; *) exit 2;; esac\ncase " $* " in *" --offline=false "*) ;; *) exit 2;; esac\nprintf "%s" "$AUDIT_GUARD_OUTPUT"\nexit "$AUDIT_GUARD_STATUS"\n')
  chmodSync(npm, 0o755)
  const root = fileURLToPath(new URL('..', import.meta.url))
  const script = fileURLToPath(new URL('./audit-check.mjs', import.meta.url))
  for (const [label, output, status, expected] of [
    ['clean audit', JSON.stringify({ ...report, vulnerabilities: {}, metadata: { ...report.metadata, vulnerabilities: { info: 0, low: 0, moderate: 0, high: 0, critical: 0, total: 0 } } }), '0', 0],
    ['invalid JSON', '{broken', '1', 1],
    ['missing metadata', '{}', '0', 1],
    ['registry error', JSON.stringify({ error: { message: 'unavailable' } }), '1', 1],
    ['unexpected npm status', JSON.stringify({ ...report, vulnerabilities: {}, metadata: { ...report.metadata, vulnerabilities: { info: 0, low: 0, moderate: 0, high: 0, critical: 0, total: 0 } } }), '2', 1],
  ]) {
    const result = spawnSync(process.execPath, [script, root], {
      encoding: 'utf8',
      env: { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`, NODE_ENV: 'production', AUDIT_GUARD_OUTPUT: output, AUDIT_GUARD_STATUS: status },
    })
    assert.equal(result.status, expected, `${label}: ${result.stdout}\n${result.stderr}`)
    if (expected) assert.doesNotMatch(result.stdout, /No unreviewed/)
  }
} finally {
  rmSync(bin, { recursive: true, force: true })
}
console.log('Audit CLI rejects registry/JSON/schema/status failures')

const consumerReport = structuredClone(report)
consumerReport.vulnerabilities['new-runtime'] = { name: 'new-runtime', severity: 'high', isDirect: true, range: '*', nodes: ['node_modules/new-runtime'], via: ['picomatch'] }
consumerReport.metadata.vulnerabilities.high = consumerReport.metadata.vulnerabilities.total = 2
assert.match(evaluateAudit(consumerReport, allowlist, { ...options, lockPackages: { ...options.lockPackages, 'node_modules/new-runtime': { dev: true } } }).problems[0], /unreviewed dependent consumer/)
assert.equal(evaluateAudit(report, allowlist, { ...options, lockPackages: { 'node_modules/picomatch': { dev: false } } }).problems.length, 1)
const reviewedReport = structuredClone(consumerReport)
reviewedReport.vulnerabilities.vite = { ...reviewedReport.vulnerabilities['new-runtime'], name: 'vite', nodes: ['node_modules/vite'] }
delete reviewedReport.vulnerabilities['new-runtime']
assert.equal(evaluateAudit(reviewedReport, allowlist, { ...options, lockPackages: { ...options.lockPackages, 'node_modules/vite': { dev: true } } }).problems.length, 0)
console.log('Reviewed consumer chains accepted; new consumers and production promotion rejected')

// A reviewed consumer name cannot cover a new resolved instance (including npm aliases).
const instanceEntry = { advisory: 'GHSA-test-instance', package: 'picomatch', project: '.', via: 'fixture', reason: 'fixture', reviewBy: '2099-01-31', isDirect: false, range: '*', nodes: ['node_modules/picomatch'], reviewedConsumers: ['vite'], reviewedConsumerNodes: ['node_modules/vite'] }
const instanceReport = { auditReportVersion: 2, vulnerabilities: {
  picomatch: { name: 'picomatch', severity: 'high', isDirect: false, range: '*', nodes: ['node_modules/picomatch'], via: [{title: 'fixture', severity: 'high', url: 'https://github.com/advisories/GHSA-test-instance'}] },
  vite: { name: 'vite', severity: 'high', isDirect: true, range: '*', nodes: ['node_modules/vite'], via: ['picomatch'] },
}, metadata: { vulnerabilities: { info: 0, low: 0, moderate: 0, high: 2, critical: 0, total: 2 }, dependencies: {prod: 0, dev: 2, optional: 0, peer: 0, peerOptional: 0, total: 2} } }
assert.equal(evaluateAudit(instanceReport, [instanceEntry], { project: '.' }).problems.length, 0)
instanceReport.vulnerabilities.vite.nodes.push('node_modules/vite-alias')
assert.match(evaluateAudit(instanceReport, [instanceEntry], { project: '.' }).problems[0], /unreviewed dependent instance/)

// A scan must use the same lockfile graph throughout its registry request.
{
  const { mkdtempSync, writeFileSync, chmodSync, rmSync } = await import('node:fs')
  const { tmpdir } = await import('node:os')
  const path = await import('node:path')
  const { spawnSync } = await import('node:child_process')
  const { fileURLToPath } = await import('node:url')
  const fixture = mkdtempSync(path.join(tmpdir(), 'audit-lock-'))
  const cleanReport = { auditReportVersion: 2, vulnerabilities: {}, metadata: { vulnerabilities: {info: 0, low: 0, moderate: 0, high: 0, critical: 0, total: 0}, dependencies: {prod: 0, dev: 0, optional: 0, peer: 0, peerOptional: 0, total: 0} } }
  try {
    writeFileSync(path.join(fixture, 'package-lock.json'), '{"packages":{}}')
    const fakeNpm = path.join(fixture, 'npm')
    writeFileSync(fakeNpm, '#!/bin/sh\ncase " $* " in *" --include=dev "*) ;; *) exit 2;; esac\ncase " $* " in *" --offline=false "*) ;; *) exit 2;; esac\nif [ "$MUTATE_AUDIT_LOCK" = 1 ]; then printf " " >> package-lock.json; fi\nprintf "%s" "$CLEAN_AUDIT_REPORT"\n')
    chmodSync(fakeNpm, 0o755)
    const script = fileURLToPath(new URL('./audit-check.mjs', import.meta.url))
    const env = { ...process.env, NODE_ENV: 'production', npm_config_offline: 'true', PATH: `${fixture}${path.delimiter}${process.env.PATH}`, CLEAN_AUDIT_REPORT: JSON.stringify(cleanReport) }
    const stable = spawnSync(process.execPath, [script, fixture], {env, encoding: 'utf8'})
    assert.equal(stable.status, 0, stable.stderr)
    const changed = spawnSync(process.execPath, [script, fixture], {env: {...env, MUTATE_AUDIT_LOCK: '1'}, encoding: 'utf8'})
    assert.equal(changed.status, 1)
    assert.match(changed.stderr, /Lockfile changed during audit/)
  } finally { rmSync(fixture, {recursive: true, force: true}) }
}
