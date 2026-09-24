#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

payroll_sha="${1:-}"
aire_sha="${2:-}"
for value in "${payroll_sha}" "${aire_sha}"; do
  [[ "${value}" =~ ^[0-9a-f]{40}$ ]] || { echo "usage: $0 <payroll-sha> <aire-sha>" >&2; exit 64; }
done

load_staging_secrets
validate_staging_configuration

state_dir="${SERVICE_DIR}/.staging-state"
mkdir -p "${state_dir}"
lock_dir="${state_dir}/deploy.lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  echo "A staging deployment is already running." >&2
  exit 75
fi
trap 'rmdir "${lock_dir}"' EXIT

previous_payroll_sha="$(cat "${state_dir}/deployed-payroll-sha" 2>/dev/null || true)"
previous_aire_sha="$(cat "${state_dir}/deployed-aire-sha" 2>/dev/null || true)"
export PAYROLL_IMAGE_TAG="${payroll_sha}"
export AIRE_IMAGE_TAG="${aire_sha}"

if [[ "${SKIP_IMAGE_PULL:-0}" != "1" ]]; then
  compose pull aire-api aire-worker aire-web payroll-api payroll-worker payroll-web
fi
compose up -d --wait aire-db payroll-db
"${SCRIPT_DIR}/backup.sh"

compose run --rm payroll-api bundle exec rails db:prepare
compose run --rm payroll-api bundle exec rails solid_queue:setup
compose run --rm aire-api bundle exec rails db:prepare
compose run --rm payroll-api bundle exec rails runner script/staging_seed.rb
compose run --rm aire-api bundle exec rails runner script/staging_seed.rb
compose up -d --remove-orphans

healthy=0
for _ in $(seq 1 "${DEPLOY_HEALTH_ATTEMPTS:-40}"); do
  if "${SCRIPT_DIR}/healthcheck.sh" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep "${DEPLOY_HEALTH_INTERVAL:-4}"
done

if [[ "${healthy}" == "1" ]]; then
  printf '%s\n' "${payroll_sha}" > "${state_dir}/deployed-payroll-sha"
  printf '%s\n' "${aire_sha}" > "${state_dir}/deployed-aire-sha"
  echo "AIRE + Cornerstone staging deployed payroll=${payroll_sha} aire=${aire_sha}."
  exit 0
fi

echo "Staging health check failed." >&2
if [[ "${previous_payroll_sha}" =~ ^[0-9a-f]{40}$ && "${previous_aire_sha}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Rolling application containers back to the previous image pair." >&2
  export PAYROLL_IMAGE_TAG="${previous_payroll_sha}"
  export AIRE_IMAGE_TAG="${previous_aire_sha}"
  compose up -d --remove-orphans
fi
exit 1
