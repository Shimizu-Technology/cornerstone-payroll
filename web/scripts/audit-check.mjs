/**
 * @typedef {{title: string, url: string, severity: string}} Advisory
 * @typedef {{name: string, severity: string, isDirect: boolean, range: string, nodes: string[], via: (string | Advisory)[]}} Finding
 * @typedef {{auditReportVersion: number, vulnerabilities: Record<string, Finding>, metadata: {vulnerabilities: Record<string, number>, dependencies: Record<string, number>}}} AuditReport
 * @typedef {{advisory: string, package: string, project: string, via: string, reason: string, reviewBy: string, isDirect: boolean, range: string, nodes: string[], reviewedConsumers?: string[], reviewedConsumerNodes?: string[], devOnly?: boolean}} Exception
 * @typedef {{project: string, today?: string, lockPackages?: Record<string, {dev?: boolean}>}} AuditOptions
 * @typedef {{problems: string[], allowed: string[]}} AuditResult
 */
// Fail closed on incomplete audit reports and narrowly scoped, dated exceptions.
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const severities = ['info', 'low', 'moderate', 'high', 'critical']
const failing = new Set(['moderate', 'high', 'critical'])
const record = (value) => value !== null && typeof value === 'object' && !Array.isArray(value)
const nonempty = (value) => typeof value === 'string' && value.trim().length > 0
const count = (value) => Number.isSafeInteger(value) && value >= 0
const isoDate = (value) => typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)
  && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value
const nodePath = (value) => nonempty(value) && value.startsWith('node_modules/')
  && !value.includes('\\') && !value.split('/').some((part) => part === '.' || part === '..' || part === '')

function requireValid(condition, message) {
  if (!condition) throw new Error(message)
}

function validateAllowlist(allowlist) {
  requireValid(Array.isArray(allowlist), 'Audit allowlist must be an array')
  for (const entry of allowlist) {
    requireValid(record(entry) && /^GHSA-[a-z0-9-]+$/.test(entry.advisory) && nonempty(entry.package)
      && ['.', 'mobile'].includes(entry.project) && nonempty(entry.reason) && nonempty(entry.via)
      && isoDate(entry.reviewBy) && nonempty(entry.range) && entry.isDirect === false
      && Array.isArray(entry.nodes) && entry.nodes.length > 0 && entry.nodes.every(nodePath)
      && (entry.reviewedConsumers === undefined || (Array.isArray(entry.reviewedConsumers) && entry.reviewedConsumers.every(nonempty)))
      && (entry.reviewedConsumerNodes === undefined || (Array.isArray(entry.reviewedConsumerNodes) && entry.reviewedConsumerNodes.every(nodePath)))
      && (entry.devOnly === undefined || typeof entry.devOnly === 'boolean'),
    'Invalid audit allowlist entry: require advisory, package, project, reason, via, real ISO reviewBy, range, indirect scope and node paths')
  }
}

function validateReport(report) {
  requireValid(record(report) && !Object.hasOwn(report, 'error'), 'npm audit returned an error payload or invalid report')
  requireValid(report.auditReportVersion === 2 && record(report.vulnerabilities)
    && record(report.metadata) && record(report.metadata.vulnerabilities)
    && record(report.metadata.dependencies), 'Incomplete or unsupported npm audit report')
  const counts = Object.fromEntries(severities.map((severity) => [severity, 0]))
  for (const [name, vulnerability] of Object.entries(report.vulnerabilities)) {
    requireValid(record(vulnerability) && vulnerability.name === name && severities.includes(vulnerability.severity)
      && typeof vulnerability.isDirect === 'boolean' && nonempty(vulnerability.range)
      && Array.isArray(vulnerability.nodes) && vulnerability.nodes.length > 0 && vulnerability.nodes.every(nodePath)
      && Array.isArray(vulnerability.via) && vulnerability.via.length > 0, `Malformed vulnerability: ${name}`)
    counts[vulnerability.severity]++
    for (const via of vulnerability.via) {
      if (typeof via === 'string') {
        requireValid(Object.hasOwn(report.vulnerabilities, via), `Missing referenced vulnerability: ${via}`)
      } else {
        requireValid(record(via) && nonempty(via.title) && nonempty(via.url)
          && severities.includes(via.severity), `Malformed advisory in ${name}`)
      }
    }
  }
  const metadata = report.metadata
  requireValid(severities.every((severity) => count(metadata.vulnerabilities[severity]) && metadata.vulnerabilities[severity] === counts[severity])
    && count(metadata.vulnerabilities.total) && metadata.vulnerabilities.total === Object.keys(report.vulnerabilities).length
    && ['prod', 'dev', 'optional', 'peer', 'peerOptional', 'total'].every((key) => count(metadata.dependencies[key])),
  'Malformed or inconsistent npm audit metadata')
  // A high transitive finding must resolve to an actual advisory, not only a
  // cycle of package-name references which would otherwise be silently skipped.
  function hasAdvisory(name, visited = new Set()) {
    if (visited.has(name)) return false
    visited.add(name)
    return report.vulnerabilities[name].via.some((via) => typeof via === 'string'
      ? hasAdvisory(via, visited) : failing.has(via.severity))
  }
  for (const [name, vulnerability] of Object.entries(report.vulnerabilities)) {
    requireValid(!failing.has(vulnerability.severity) || hasAdvisory(name), `High/critical finding has no advisory: ${name}`)
  }
}

/** @param {AuditReport} report @param {Exception[]} allowlist @param {AuditOptions} options @returns {AuditResult} */
export function evaluateAudit(report, allowlist, { project, today = new Date().toISOString().slice(0, 10), lockPackages = {} }) {
  validateAllowlist(allowlist)
  validateReport(report)
  requireValid(isoDate(today), 'Invalid audit evaluation date')
  function dependsOn(name, dependency, visited = new Set()) {
    if (name === dependency) return true
    if (visited.has(name)) return false
    visited.add(name)
    return report.vulnerabilities[name].via.some(via => typeof via === 'string' && dependsOn(via, dependency, visited))
  }
  const problems = []
  const allowed = []
  for (const [name, vulnerability] of Object.entries(report.vulnerabilities)) {
    for (const via of vulnerability.via) {
      if (typeof via === 'string' || !failing.has(via.severity)) continue
      const id = via.url.split('/').pop()
      const matches = allowlist.filter((item) => item.advisory === id && item.package === name)
      const entry = matches.find((item) => item.project === project) ?? matches[0]
      if (!entry) {
        problems.push(`${name}: ${via.title} (${via.url})`)
      } else if (entry.project !== project || vulnerability.isDirect !== entry.isDirect
        || vulnerability.range !== entry.range || !vulnerability.nodes.every((node) => entry.nodes.includes(node))) {
        problems.push(`${name}: ${id} falls outside the reviewed project/dependency scope`)
      } else if (entry.reviewedConsumers && Object.keys(report.vulnerabilities).some(consumer =>
        consumer !== name && dependsOn(consumer, name) && !entry.reviewedConsumers.includes(consumer))) {
        problems.push(`${name}: ${id} has an unreviewed dependent consumer`)
      } else if (entry.reviewedConsumerNodes && Object.entries(report.vulnerabilities).some(([consumer, finding]) =>
        consumer !== name && dependsOn(consumer, name) && finding.nodes.some(node => !entry.reviewedConsumerNodes.includes(node)))) {
        problems.push(`${name}: ${id} has an unreviewed dependent instance`)
      } else if (entry.devOnly && Object.entries(report.vulnerabilities).some(([consumer, finding]) =>
        dependsOn(consumer, name) && finding.nodes.some(node => lockPackages[node]?.dev !== true))) {
        problems.push(`${name}: ${id} is no longer confined to development-only dependencies`)
      } else if (entry.reviewBy < today) {
        problems.push(`${name}: allowlist entry for ${id} expired on ${entry.reviewBy}; review it again`)
      } else {
        allowed.push(`allowed ${id} in ${name} until ${entry.reviewBy}: ${entry.reason}`)
      }
    }
  }
  return { problems, allowed }
}

/** @param {string} target @returns {void} */
export function runAudit(target) {
  const lockPath = path.join(target, 'package-lock.json')
  const lockSnapshot = readFileSync(lockPath, 'utf8')
  let output
  try {
    output = execFileSync('npm', ['audit', '--json', '--include=dev', '--include=optional', '--include=peer', '--offline=false', '--prefer-offline=false', '--prefer-online=true'], { cwd: target, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
  } catch (error) {
    // npm uses exit 1 for advisories. Signals, spawn errors and other statuses
    // are operational failures even if stdout happens to contain valid JSON.
    if (error.status !== 1 || !error.stdout) throw error
    output = error.stdout
  }
  const root = fileURLToPath(new URL('..', import.meta.url))
  const project = path.relative(root, target).split(path.sep).join('/') || '.'
  const allowlist = JSON.parse(readFileSync(new URL('./audit-allowlist.json', import.meta.url), 'utf8'))
  requireValid(readFileSync(lockPath, 'utf8') === lockSnapshot, 'Lockfile changed during audit; rerun against a stable dependency graph')
  const lock = JSON.parse(lockSnapshot)
  requireValid(record(lock.packages), 'Missing resolved lockfile dependency graph')
  const { problems, allowed } = evaluateAudit(JSON.parse(output), allowlist, { project, lockPackages: lock.packages })
  allowed.forEach((message) => console.log(message))
  if (problems.length) throw new Error(`High or critical advisories in ${target}:\n- ${problems.join('\n- ')}`)
  console.log(`No unreviewed high or critical advisories in ${target}.`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    runAudit(path.resolve(process.argv[2] ?? '.'))
  } catch (error) {
    console.error(`Audit check failed: ${error.message}`)
    process.exitCode = 1
  }
}
