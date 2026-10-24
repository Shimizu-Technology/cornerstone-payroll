export const isStaging = import.meta.env.VITE_DEPLOYMENT_ENV === 'staging'
export const stagingLabel = 'STAGING – DO NOT ISSUE OR FILE'
export const stagingSnapshot = import.meta.env.VITE_STAGING_SNAPSHOT_AT || 'Snapshot not recorded'
export const stagingCodeSha = import.meta.env.VITE_STAGING_CODE_SHA || 'Code SHA not recorded'

export function stagingCsv(csv: string): string {
  return isStaging ? `${stagingLabel}\n${csv}` : csv
}
