#!/usr/bin/env bash
set -euo pipefail

payroll_sha="${1:-}"
aire_sha="${2:-}"
requested_run_id="${3:-}"
for value in "${payroll_sha}" "${aire_sha}"; do
  [[ "${value}" =~ ^[0-9a-f]{40}$ ]] || { echo "A certificate requires two full commit SHAs." >&2; exit 64; }
done
[[ -z "${requested_run_id}" || "${requested_run_id}" =~ ^[1-9][0-9]*$ ]] || exit 64

repo="Shimizu-Technology/cornerstone-payroll"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/connected-payroll-certificate.XXXXXX")"
trap 'rm -rf -- "${temporary_dir}"' EXIT

if [[ -z "${requested_run_id}" ]]; then
  if ! gh run list --repo "${repo}" --workflow quality.yml \
      --branch staging-v2 --event workflow_dispatch --limit 100 \
      --json databaseId,displayTitle,createdAt > "${temporary_dir}/runs.json"; then
    echo "Unable to retrieve connected-payroll certificates; deployment held." >&2
    exit 1
  fi
  requested_run_id="$(python3 - "${temporary_dir}/runs.json" "${payroll_sha}" "${aire_sha}" <<'PY'
import json, sys
runs = json.load(open(sys.argv[1]))
title = f"Connected payroll {sys.argv[2]} + {sys.argv[3]}"
matches = sorted((run for run in runs if run.get("displayTitle") == title),
                 key=lambda run: run["createdAt"], reverse=True)
if matches:
    print(matches[0]["databaseId"])
PY
)"
fi
if [[ -z "${requested_run_id}" ]]; then
  echo "This commit pair has no connected-payroll certificate; deployment held." >&2
  exit 1
fi

gh api "repos/${repo}/actions/runs/${requested_run_id}" > "${temporary_dir}/run.json"
run_attempt="$(python3 - "${temporary_dir}/run.json" "${payroll_sha}" "${aire_sha}" "${requested_run_id}" <<'PY'
import json, sys
run = json.load(open(sys.argv[1]))
expected = {
    "id": int(sys.argv[4]), "status": "completed", "conclusion": "success",
    "event": "workflow_dispatch", "head_branch": "staging-v2",
    "name": "Quality", "path": ".github/workflows/quality.yml",
    "display_title": f"Connected payroll {sys.argv[2]} + {sys.argv[3]}",
}
if any(run.get(key) != value for key, value in expected.items()):
    sys.exit("Connected-payroll certification is pending, failed, or does not match; deployment held.")
attempt = run.get("run_attempt")
if not isinstance(attempt, int) or attempt < 1:
    sys.exit("Invalid connected-payroll run attempt; deployment held.")
print(attempt)
PY
)"
gh run download "${requested_run_id}" --repo "${repo}" \
  --name "connected-payroll-pair-${requested_run_id}-${run_attempt}" \
  --dir "${temporary_dir}/certificate" >/dev/null

python3 - "${temporary_dir}/run.json" "${temporary_dir}/certificate/pair-certificate.json" \
    "${payroll_sha}" "${aire_sha}" <<'PY'
import json, sys
run = json.load(open(sys.argv[1]))
certificate = json.load(open(sys.argv[2]))
expected = {
    "schema_version": 1, "certification": "passed", "lane": "real-http-synthetic-v1",
    "payroll_sha": sys.argv[3], "aire_sha": sys.argv[4],
    "workflow_sha": run["head_sha"], "run_id": run["id"], "run_attempt": run["run_attempt"],
}
if certificate != expected:
    sys.exit("Connected-payroll certificate evidence does not match this run and pair; deployment held.")
print(run["id"])
PY
