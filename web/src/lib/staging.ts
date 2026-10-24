export const isStaging = import.meta.env.VITE_DEPLOYMENT_ENV === 'staging'
export const stagingLabel = 'STAGING – DO NOT ISSUE OR FILE'
export const stagingSnapshot = import.meta.env.VITE_STAGING_SNAPSHOT_AT || 'Snapshot not recorded'
export const stagingCodeSha = import.meta.env.VITE_STAGING_CODE_SHA || 'Code SHA not recorded'

export function stagingCsv(csv: string): string {
  return isStaging ? `${stagingLabel}\n${csv}` : csv
}

export function stagingFilename(filename: string): string {
  return isStaging && !filename.startsWith('STAGING_') ? `STAGING_${filename}` : filename
}

/** Fail closed before browser navigation; copied backend host lists are not trusted. */
export function stagingNavigationUrl(value: string, savedOrigin?: string | null): string {
  if (!isStaging) return value
  const reject = (): never => { throw new Error('Invalid staging connection destination. Refresh and ask your administrator to check the staging origins.') }
  const configured = import.meta.env.VITE_STAGING_AIRE_FRONTEND_ORIGIN
  if (!configured) return reject()
  let origin: URL
  let url: URL
  try { origin = new URL(configured); url = new URL(value) } catch { return reject() }
  if (origin.protocol !== 'https:' || configured !== origin.origin ||
      !/(?:^|[.-])staging(?:[.-]|$)/.test(origin.hostname) || origin.port ||
      url.origin !== origin.origin || url.username || url.password || url.hash ||
      !value.startsWith(`${origin.origin}/`) || (savedOrigin != null && savedOrigin !== origin.origin)) return reject()
  return url.toString()
}
