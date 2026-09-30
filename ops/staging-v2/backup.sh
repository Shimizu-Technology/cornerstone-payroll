#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
load_staging_secrets

BACKUP_DIR="${AIRE_PAYROLL_STAGING_V2_BACKUP_DIR:-${SERVICE_DIR}/backups-staging-v2}"
mkdir -p "${BACKUP_DIR}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
postgres_image="postgres:16-alpine@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685"

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

backup_volume() {
  local logical_name="$1" prefix="$2" volume_name backup_path temporary_path
  volume_name="$(
    docker --context "${DOCKER_CONTEXT}" volume ls \
      --filter "label=com.docker.compose.project=aire-payroll-staging-v2" \
      --filter "label=com.docker.compose.volume=${logical_name}" \
      --format '{{.Name}}'
  )"
  if [[ -z "${volume_name}" ]]; then
    printf 'Skipping %s; the staging v2 volume does not exist yet.\n' "${logical_name}" >&2
    return 0
  fi
  [[ "${volume_name}" != *$'\n'* ]] || {
    echo "Unable to resolve the ${logical_name} staging v2 volume." >&2
    return 1
  }

  backup_path="${BACKUP_DIR}/${prefix}-${timestamp}.tar.gz"
  temporary_path="$(mktemp "${backup_path}.tmp.XXXXXX")"
  if docker --context "${DOCKER_CONTEXT}" run --rm --read-only --network none \
      --volume "${volume_name}:/source:ro" \
      --entrypoint tar "${postgres_image}" -C /source -czf - . > "${temporary_path}"; then
    mv "${temporary_path}" "${backup_path}"
  else
    rm -f "${temporary_path}"
    return 1
  fi
  printf '%s\n' "${backup_path}"
}

backup_database aire-db aire_staging_v2 aire_services_staging_v2 aire-services-staging-v2
backup_database payroll-db payroll_staging_v2 cornerstone_payroll_staging_v2 cornerstone-payroll-staging-v2
backup_volume aire_storage aire-storage-staging-v2
backup_volume payroll_storage cornerstone-payroll-storage-staging-v2
mkdir -p "${SERVICE_DIR}/.staging-v2-state"
touch "${SERVICE_DIR}/.staging-v2-state/last-successful-backup"
find "${BACKUP_DIR}" -type f \( -name '*-staging-v2-*.sql.gz' -o -name '*-staging-v2-*.tar.gz' \) -mtime +14 -delete
