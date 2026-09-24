#!/usr/bin/env bash
set -euo pipefail

profile="aire-payroll-staging"
if ! colima status --profile "${profile}" >/dev/null 2>&1; then
  colima start --profile "${profile}" --cpu 4 --memory 8 --disk 50 --runtime docker
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/poll-once.sh"

state_dir="$(cd "${SCRIPT_DIR}/../.." && pwd)/.staging-state"
backup_marker="${state_dir}/last-successful-backup"
if [[ ! -f "${backup_marker}" ]] || [[ -n "$(find "${backup_marker}" -mmin +1439 -print -quit)" ]]; then
  "${SCRIPT_DIR}/backup.sh"
fi
