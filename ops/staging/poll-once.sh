#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

state_dir="${SERVICE_DIR}/.staging-state"
mkdir -p "${state_dir}"

latest_successful_sha() {
  local repo="$1" workflow="$2"
  gh run list \
    --repo "Shimizu-Technology/${repo}" \
    --workflow "${workflow}" \
    --branch staging \
    --event push \
    --status success \
    --limit 1 \
    --json headSha \
    --jq '.[0].headSha // ""'
}

payroll_sha="$(latest_successful_sha cornerstone-payroll quality.yml)" || exit 0
aire_sha="$(latest_successful_sha aire-services staging.yml)" || exit 0
[[ "${payroll_sha}" =~ ^[0-9a-f]{40}$ && "${aire_sha}" =~ ^[0-9a-f]{40}$ ]] || exit 0

deployed_payroll_sha="$(cat "${state_dir}/deployed-payroll-sha" 2>/dev/null || true)"
deployed_aire_sha="$(cat "${state_dir}/deployed-aire-sha" 2>/dev/null || true)"
if [[ "${payroll_sha}" == "${deployed_payroll_sha}" && "${aire_sha}" == "${deployed_aire_sha}" ]]; then
  exit 0
fi

git -C "${SERVICE_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "The staging service directory is not a Git checkout." >&2; exit 1; }
if [[ -n "$(git -C "${SERVICE_DIR}" status --porcelain --untracked-files=no)" ]]; then
  echo "Tracked deployment files have local changes; refusing to overwrite them." >&2
  exit 1
fi
git -C "${SERVICE_DIR}" fetch --quiet origin staging
git -C "${SERVICE_DIR}" cat-file -e "${payroll_sha}^{commit}"
git -C "${SERVICE_DIR}" checkout --quiet --detach "${payroll_sha}"
exec "${SERVICE_DIR}/ops/staging/deploy.sh" "${payroll_sha}" "${aire_sha}"
