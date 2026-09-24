#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
load_staging_secrets
validate_staging_configuration

curl --fail --silent --show-error --output /dev/null --connect-timeout 5 --max-time 15 "http://${STAGING_BIND_ADDRESS}:${AIRE_STAGING_PORT}/health"
curl --fail --silent --show-error --output /dev/null --connect-timeout 5 --max-time 15 "http://${STAGING_BIND_ADDRESS}:${PAYROLL_STAGING_PORT}/health"

worker_is_stable() {
  local service="$1" container_id state restarting restart_count
  container_id="$(compose ps -q "${service}")"
  [[ -n "${container_id}" ]] || return 1
  read -r state restarting restart_count < <(
    docker --context "${DOCKER_CONTEXT}" inspect \
      --format '{{.State.Status}} {{.State.Restarting}} {{.RestartCount}}' \
      "${container_id}"
  )
  [[ "${state}" == "running" && "${restarting}" == "false" && "${restart_count}" == "0" ]]
}

worker_is_stable aire-worker
worker_is_stable payroll-worker
