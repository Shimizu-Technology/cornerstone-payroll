#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
load_staging_secrets

BACKUP_DIR="${AIRE_PAYROLL_STAGING_BACKUP_DIR:-${SERVICE_DIR}/backups}"
mkdir -p "${BACKUP_DIR}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

backup_database() {
  local service="$1" user="$2" database="$3" prefix="$4"
  compose ps --status running --services | grep -qx "${service}" || return 0
  local backup_path="${BACKUP_DIR}/${prefix}-${timestamp}.sql.gz"
  local temporary_path
  temporary_path="$(mktemp "${backup_path}.tmp.XXXXXX")"
  if compose exec -T "${service}" pg_dump --username "${user}" --dbname "${database}" --no-owner --no-privileges |
      gzip > "${temporary_path}"; then
    mv "${temporary_path}" "${backup_path}"
  else
    rm -f "${temporary_path}"
    return 1
  fi
  printf '%s\n' "${backup_path}"
}

backup_database aire-db aire_staging aire_services_staging aire-services-staging
backup_database payroll-db payroll_staging cornerstone_payroll_staging cornerstone-payroll-staging
find "${BACKUP_DIR}" -type f -name '*-staging-*.sql.gz' -mtime +14 -delete
